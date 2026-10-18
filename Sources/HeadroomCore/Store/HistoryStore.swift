import Foundation
import HeadroomKit

/// Glide history and past weeks, keyed by account (PLAN §4.3 item 7). History starts at
/// install; nothing is estimated or backfilled.
public struct HistoryStore: Codable, Sendable, Hashable {
    public static let maxSamples = 700
    public static let maxWeeks = 26
    public static let weekSampleLimit = 168

    public var accounts: [String: AccountHistory] = [:]

    public init() {}

    public static func key(_ provider: Provider, account: String?) -> String {
        provider.rawValue + ":" + (account ?? "default")
    }

    public func account(_ provider: Provider, _ account: String?) -> AccountHistory? {
        accounts[Self.key(provider, account: account)]
    }

    /// Records one reading: appends glide samples, closes finished weeks, detects early resets
    /// and counts 5-hour limit hits.
    public mutating func record(_ reading: LimitReading, now: Date) {
        let key = Self.key(reading.provider, account: reading.accountKey)
        var acct = accounts[key] ?? AccountHistory()
        let plan = reading.plan?.pill

        // Every long window keeps its own glide (the headline and any model caps).
        for window in reading.windows where window.kind != .session {
            guard let resetsAt = window.resetsAt else { continue }
            let isHeadline = window.id == reading.headline?.id
            if var current = acct.windows[window.id] {
                if resetsAt.timeIntervalSince(current.resetsAt) > 3600 {
                    // The window rolled over. Early when it happened well before the old reset time.
                    let early = now < current.resetsAt.addingTimeInterval(-3600)
                    if isHeadline {
                        acct.weeks.append(current.close(endedAt: early ? now : current.resetsAt, early: early,
                                                        sessionHits: acct.sessionHitsThisWindow, plan: acct.planThisWindow ?? plan))
                        if acct.weeks.count > Self.maxWeeks { acct.weeks.removeFirst(acct.weeks.count - Self.maxWeeks) }
                        acct.sessionHitsThisWindow = 0
                        acct.earlyResetAt = early ? now : nil
                        acct.tracker = nil
                        acct.planThisWindow = plan
                    }
                    current = WindowHistory(id: window.id, resetsAt: resetsAt, duration: window.effectiveDuration)
                } else if abs(resetsAt.timeIntervalSince(current.resetsAt)) > 1 {
                    current.resetsAt = resetsAt // jitter in the reported reset time
                }
                current.append(UsageSample(time: now, used: window.used))
                acct.windows[window.id] = current
            } else {
                var fresh = WindowHistory(id: window.id, resetsAt: resetsAt, duration: window.effectiveDuration)
                fresh.append(UsageSample(time: now, used: window.used))
                acct.windows[window.id] = fresh
                if isHeadline, acct.planThisWindow == nil { acct.planThisWindow = plan }
            }
        }
        // Drop windows the provider stopped reporting.
        let live = Set(reading.windows.map(\.id))
        acct.windows = acct.windows.filter { live.contains($0.key) }

        // 5-hour limit hits: count each blocked session once.
        if let s = reading.session, s.used >= 1, let r = s.resetsAt, acct.lastBlockedSessionReset.map({ abs($0.timeIntervalSince(r)) > 60 }) ?? true {
            acct.sessionHitsThisWindow += 1
            acct.lastBlockedSessionReset = r
        }
        acct.headlineID = reading.headline?.id
        accounts[key] = acct
    }

    /// Samples for one window of one account.
    public func samples(_ provider: Provider, account: String?, window: String) -> [UsageSample] {
        accounts[Self.key(provider, account: account)]?.windows[window]?.samples ?? []
    }
}

public struct AccountHistory: Codable, Sendable, Hashable {
    public var windows: [String: WindowHistory] = [:]
    public var weeks: [WeekRecord] = []
    public var headlineID: String?
    public var sessionHitsThisWindow = 0
    public var lastBlockedSessionReset: Date?
    public var earlyResetAt: Date?
    public var planThisWindow: String?
    public var tracker: PacingTracker?

    public init() {}

    public var headline: WindowHistory? { headlineID.flatMap { windows[$0] } }
}

public struct WindowHistory: Codable, Sendable, Hashable {
    public var id: String
    public var resetsAt: Date
    public var duration: TimeInterval
    public var samples: [UsageSample] = []

    public init(id: String, resetsAt: Date, duration: TimeInterval) {
        self.id = id
        self.resetsAt = resetsAt
        self.duration = duration
    }

    public var start: Date { resetsAt.addingTimeInterval(-duration) }

    /// Appends when usage moved or 30 minutes passed; keeps at most `maxSamples` by thinning
    /// the older half.
    public mutating func append(_ s: UsageSample) {
        if let last = samples.last {
            guard s.time > last.time else { return }
            if abs(s.used - last.used) < 0.0005, s.time.timeIntervalSince(last.time) < 1800 { return }
        }
        samples.append(s)
        if samples.count > HistoryStore.maxSamples {
            let half = samples.count / 2
            let thinned = samples[..<half].enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            samples = thinned + samples[half...]
        }
    }

    func close(endedAt: Date, early: Bool, sessionHits: Int, plan: String?) -> WeekRecord {
        let final = samples.last?.used ?? 0
        let ranOut = samples.first { $0.used >= 1 }?.time
        var kept = samples
        if kept.count > HistoryStore.weekSampleLimit {
            let stride = Double(kept.count) / Double(HistoryStore.weekSampleLimit)
            kept = (0..<HistoryStore.weekSampleLimit).map { kept[min(kept.count - 1, Int(Double($0) * stride))] } + [kept[kept.count - 1]]
        }
        return WeekRecord(start: start, end: endedAt, scheduledEnd: resetsAt, finalUsed: final, ranOutAt: ranOut,
                          sessionHits: sessionHits, earlyReset: early, plan: plan, samples: kept)
    }
}

/// One finished renewal window.
public struct WeekRecord: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var scheduledEnd: Date
    public var finalUsed: Double
    public var ranOutAt: Date?
    public var sessionHits: Int
    public var earlyReset: Bool
    public var plan: String?
    public var samples: [UsageSample]

    public init(start: Date, end: Date, scheduledEnd: Date, finalUsed: Double, ranOutAt: Date?, sessionHits: Int, earlyReset: Bool, plan: String?, samples: [UsageSample]) {
        self.start = start; self.end = end; self.scheduledEnd = scheduledEnd; self.finalUsed = finalUsed; self.ranOutAt = ranOutAt
        self.sessionHits = sessionHits; self.earlyReset = earlyReset; self.plan = plan; self.samples = samples
    }

    /// Hours between running out and the scheduled renewal.
    public var hoursEarly: Int? {
        guard let r = ranOutAt else { return nil }
        let h = scheduledEnd.timeIntervalSince(r) / 3600
        return h >= 1 ? Int(h.rounded()) : nil
    }

    public var ranOut: Bool { finalUsed >= 1 || ranOutAt != nil }
}
