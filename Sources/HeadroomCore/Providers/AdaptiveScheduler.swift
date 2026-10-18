import Foundation
import HeadroomKit

public struct SchedulerPolicy: Sendable, Hashable {
    /// Limit reads while the logs showed activity in the last `activityWindow`.
    public var activeInterval: TimeInterval = 5 * 60
    public var idleInterval: TimeInterval = 15 * 60
    public var activityWindow: TimeInterval = 10 * 60
    /// Opening the popover reads any provider whose reading is older than this.
    public var popoverStaleness: TimeInterval = 60
    /// A passive Codex reading from an `openai` session this fresh means no spawn is needed.
    public var passiveCodexFreshness: TimeInterval = 15 * 60
    public var statusInterval: TimeInterval = 15 * 60
    /// Timer leeway as a fraction of the delay, so macOS can coalesce wakeups (10–20%).
    public var leewayFraction: Double = 0.15

    public init() {}

    public static let standard = SchedulerPolicy()
}

public enum ScheduledAction: Sendable, Hashable {
    case readLimits(Provider)
    case checkStatus(Provider)
}

/// Decides when to read limits and status pages (PLAN §4.2). Pure: every method takes `now`,
/// so tests drive it with a fake clock. The app owns one and arms a single timer at `nextDeadline`.
public struct AdaptiveScheduler: Sendable, Hashable {
    public var policy: SchedulerPolicy
    public var enabled: Set<Provider>
    public var statusChecksEnabled: Bool

    public private(set) var isAsleep = false
    public private(set) var isLocked = false
    public private(set) var lastRead: [Provider: Date] = [:]
    public private(set) var retryAt: [Provider: Date] = [:]
    public private(set) var lastLogActivity: Date?
    public private(set) var lastPassiveCodex: Date?
    public private(set) var lastStatus: [Provider: Date] = [:]
    private var forcedReads: Set<Provider> = []
    private var forcedStatus: Set<Provider> = []

    public init(policy: SchedulerPolicy = .standard, enabled: Set<Provider> = Set(Provider.allCases), statusChecksEnabled: Bool = true) {
        self.policy = policy
        self.enabled = enabled
        self.statusChecksEnabled = statusChecksEnabled
    }

    public var isPaused: Bool { isAsleep || isLocked }

    public func limitInterval(at now: Date) -> TimeInterval {
        if let last = lastLogActivity, now.timeIntervalSince(last) < policy.activityWindow { return policy.activeInterval }
        return policy.idleInterval
    }

    /// True while a fresh passive reading makes spawning `codex app-server` unnecessary.
    public func codexPassiveIsFresh(at now: Date) -> Bool {
        guard let p = lastPassiveCodex else { return false }
        return now.timeIntervalSince(p) < policy.passiveCodexFreshness
    }

    public func nextLimitRead(for provider: Provider, at now: Date) -> Date? {
        guard enabled.contains(provider), !isPaused else { return nil }
        var due: Date
        if forcedReads.contains(provider) {
            due = now
        } else if let retry = retryAt[provider] {
            due = retry
        } else if let last = lastRead[provider] {
            due = last.addingTimeInterval(limitInterval(at: now))
        } else {
            due = now
        }
        if provider == .codex, let passive = lastPassiveCodex, codexPassiveIsFresh(at: now) {
            due = max(due, passive.addingTimeInterval(policy.passiveCodexFreshness))
        }
        return due
    }

    public func nextStatusCheck(for provider: Provider, at now: Date) -> Date? {
        guard statusChecksEnabled, enabled.contains(provider), !isPaused else { return nil }
        if forcedStatus.contains(provider) { return now }
        guard let last = lastStatus[provider] else { return now }
        return last.addingTimeInterval(policy.statusInterval)
    }

    public func nextDeadline(at now: Date) -> Date? {
        var dates: [Date] = []
        for p in Provider.allCases {
            if let d = nextLimitRead(for: p, at: now) { dates.append(d) }
            if let d = nextStatusCheck(for: p, at: now) { dates.append(d) }
        }
        return dates.min()
    }

    /// Everything due at `now`.
    public func due(at now: Date) -> [ScheduledAction] {
        var actions: [ScheduledAction] = []
        for p in Provider.allCases {
            if let d = nextLimitRead(for: p, at: now), d <= now { actions.append(.readLimits(p)) }
            if let d = nextStatusCheck(for: p, at: now), d <= now { actions.append(.checkStatus(p)) }
        }
        return actions
    }

    /// Timer leeway for a deadline `delay` seconds away.
    public func leeway(forDelay delay: TimeInterval) -> TimeInterval {
        let fraction = min(max(policy.leewayFraction, 0.10), 0.20)
        return max(delay, 1) * fraction
    }

    // MARK: Events

    /// A limit read finished. `retryAt` comes from the fault machine (nil when healthy).
    public mutating func recordLimitRead(_ provider: Provider, at now: Date, succeeded: Bool, retryAt: Date?) {
        lastRead[provider] = now
        forcedReads.remove(provider)
        self.retryAt[provider] = succeeded ? nil : retryAt
        if !succeeded { forcedStatus.insert(provider) }
    }

    public mutating func recordStatusCheck(_ provider: Provider, at now: Date) {
        lastStatus[provider] = now
        forcedStatus.remove(provider)
    }

    public mutating func logActivity(at now: Date) {
        lastLogActivity = now
    }

    /// A Codex log line from an `openai` session carried `rate_limits`.
    public mutating func passiveCodexReading(at time: Date) {
        if time > (lastPassiveCodex ?? .distantPast) { lastPassiveCodex = time }
    }

    public mutating func sleep() { isAsleep = true }

    /// Waking fires every enabled read at once.
    public mutating func wake(at now: Date) {
        isAsleep = false
        forcedReads.formUnion(enabled)
    }

    public mutating func screenLocked() { isLocked = true }

    public mutating func screenUnlocked(at now: Date) {
        isLocked = false
        for p in enabled where now.timeIntervalSince(lastRead[p] ?? .distantPast) >= limitInterval(at: now) {
            forcedReads.insert(p)
        }
    }

    /// Opening the popover reads any provider whose reading is older than a minute.
    public mutating func popoverOpened(at now: Date) {
        for p in enabled where now.timeIntervalSince(lastRead[p] ?? .distantPast) > policy.popoverStaleness {
            forcedReads.insert(p)
        }
    }

    /// The network came back: retry providers whose fault waits on the path.
    public mutating func pathSatisfied(retrying providers: Set<Provider>) {
        forcedReads.formUnion(providers.intersection(enabled))
    }

    /// An explicit refresh (the CLI's `--refresh` or the refresh button).
    public mutating func refreshNow(_ providers: Set<Provider>? = nil) {
        forcedReads.formUnion((providers ?? enabled).intersection(enabled))
    }
}

/// One coalescable timer (`DispatchSourceTimer` with leeway) that the app re-arms at the
/// scheduler's next deadline.
public final class SchedulerTimer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: DispatchSourceTimer?

    public init(queue: DispatchQueue = DispatchQueue(label: "headroom.scheduler", qos: .utility)) {
        self.queue = queue
    }

    public func arm(at deadline: Date, leeway: TimeInterval, now: Date = Date(), handler: @escaping @Sendable () -> Void) {
        let delay = max(deadline.timeIntervalSince(now), 0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(Int(leeway * 1000)))
        timer.setEventHandler(handler: handler)
        lock.lock()
        source?.cancel()
        source = timer
        lock.unlock()
        timer.resume()
    }

    public func cancel() {
        lock.lock()
        source?.cancel()
        source = nil
        lock.unlock()
    }

    deinit { source?.cancel() }
}
