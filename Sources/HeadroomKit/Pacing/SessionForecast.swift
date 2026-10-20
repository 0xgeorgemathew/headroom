import Foundation

/// Where the 5-hour session is heading: how fast it's burning, whether it lasts to its reset,
/// and when it would run out. The session counterpart of `PacingAnalysis`.
public struct SessionForecast: Sendable, Hashable {
    public enum Outlook: String, Sendable, Hashable {
        /// No session running: nothing used yet, or the last one already reset.
        case idle
        /// At this rate a good share is still left when it resets.
        case comfortable
        /// At this rate it lasts to its reset, with little to spare.
        case lasts
        /// At this rate it runs out before it resets.
        case runsOut
        /// Fully used; waiting for the reset.
        case blocked
    }

    public var used: Double
    public var resetsAt: Date?
    public var startedAt: Date?
    /// Elapsed fraction of the 5 hours, 0…1.
    public var elapsed: Double
    public var timeLeft: TimeInterval
    /// Used fraction per hour: the last 30 minutes when there are samples for it, else the session average.
    public var burnPerHour: Double?
    /// When the session runs out at `burnPerHour`, if that comes before the reset.
    public var runsOutAt: Date?
    /// Fraction left when it resets at `burnPerHour`.
    public var leftAtReset: Double?
    public var outlook: Outlook
    /// The same sustainable multiple as the week: remaining ÷ time-left fraction.
    public var multiple: Double

    public var remaining: Double { max(0, 1 - used) }
    public var isActive: Bool { outlook != .idle }

    /// The pacing color the session reads as, for the menu bar when it tracks the session.
    public var pacingState: PacingState {
        switch outlook {
        case .idle: .plenty
        case .blocked: .veryTight
        case .runsOut: remaining < 0.15 ? .veryTight : .tight
        case .lasts: remaining < 0.10 ? .tight : .onPace
        case .comfortable: (leftAtReset ?? remaining) >= 0.4 ? .plenty : .onPace
        }
    }

    /// Share left at the reset above which the outlook reads as comfortable.
    public static let comfortableLeft = 0.25

    public init(window: LimitWindow?, samples: [UsageSample], now: Date) {
        guard let window, window.kind == .session else {
            self.init(idleAt: now)
            return
        }
        let duration = window.effectiveDuration
        guard let resetsAt = window.resetsAt, resetsAt > now, window.used > 0 else {
            self.init(idleAt: now)
            return
        }
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsedSeconds = min(max(now.timeIntervalSince(start), 0), duration)
        let timeLeft = resetsAt.timeIntervalSince(now)
        let used = window.used
        let remaining = max(0, 1 - used)

        let burn = Self.burnRate(samples: samples, used: used, start: start, now: now)
        var runsOutAt: Date?
        var leftAtReset: Double?
        if let burn {
            leftAtReset = max(0, remaining - burn * timeLeft / 3600)
            if burn > 0, remaining / burn * 3600 < timeLeft { runsOutAt = now.addingTimeInterval(remaining / burn * 3600) }
        }

        let outlook: Outlook
        if used >= 1 {
            outlook = .blocked
        } else if runsOutAt != nil {
            outlook = .runsOut
        } else if (leftAtReset ?? remaining) >= Self.comfortableLeft {
            outlook = .comfortable
        } else {
            outlook = .lasts
        }
        let tau = timeLeft / duration
        self.init(used: used, resetsAt: resetsAt, startedAt: start, elapsed: elapsedSeconds / duration, timeLeft: timeLeft,
                  burnPerHour: burn, runsOutAt: runsOutAt, leftAtReset: leftAtReset, outlook: outlook,
                  multiple: tau > 0 ? remaining / tau : (remaining > 0 ? .infinity : 0))
    }

    private init(idleAt now: Date) {
        self.init(used: 0, resetsAt: nil, startedAt: nil, elapsed: 0, timeLeft: 0, burnPerHour: nil, runsOutAt: nil,
                  leftAtReset: nil, outlook: .idle, multiple: .infinity)
    }

    private init(used: Double, resetsAt: Date?, startedAt: Date?, elapsed: Double, timeLeft: TimeInterval, burnPerHour: Double?,
                 runsOutAt: Date?, leftAtReset: Double?, outlook: Outlook, multiple: Double) {
        self.used = used
        self.resetsAt = resetsAt
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.timeLeft = timeLeft
        self.burnPerHour = burnPerHour
        self.runsOutAt = runsOutAt
        self.leftAtReset = leftAtReset
        self.outlook = outlook
        self.multiple = multiple
    }

    /// The recent burn: change over the last 30 minutes when samples cover it, otherwise the
    /// average since the session began. Needs 10 minutes of session to say anything.
    public static func burnRate(samples: [UsageSample], used: Double, start: Date, now: Date) -> Double? {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 600 else { return nil }
        let recent = now.addingTimeInterval(-1800)
        let inSession = samples.filter { $0.time >= start && $0.time <= now }.sorted { $0.time < $1.time }
        if let base = inSession.last(where: { $0.time <= recent }), recent > start {
            let span = now.timeIntervalSince(base.time)
            // A recent burn of zero is real (a pause), but don't let one quiet half hour hide a heavy session.
            let recentBurn = max(0, used - base.used) / (span / 3600)
            let average = used / (elapsed / 3600)
            return max(recentBurn, average * 0.5)
        }
        return used / (elapsed / 3600)
    }
}
