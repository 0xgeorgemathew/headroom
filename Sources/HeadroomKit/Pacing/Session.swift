import Foundation

extension SessionLevel {
    /// Warning level for a 5-hour session's used fraction (PLAN §2.3).
    public init(used: Double, policy: PacingPolicy = .standard) {
        if used >= policy.sessionBlocked {
            self = .blocked
        } else if used >= policy.sessionRose {
            self = .rose
        } else if used >= policy.sessionAmber {
            self = .amber
        } else {
            self = .normal
        }
    }
}

/// The 5-hour session at a glance: the row, the banner and the menu-bar timer all read this.
public struct SessionStatus: Codable, Sendable, Hashable {
    public var level: SessionLevel
    public var used: Double
    public var resetsAt: Date?
    /// Seconds until the session resets, when known.
    public var countdown: TimeInterval?

    public var remaining: Double { max(0, 1 - used) }
    /// The banner (and the menu-bar timer) show from amber up; below that it's a row.
    public var showsBanner: Bool { level >= .amber }

    public init(level: SessionLevel, used: Double, resetsAt: Date?, countdown: TimeInterval?) {
        self.level = level
        self.used = used
        self.resetsAt = resetsAt
        self.countdown = countdown
    }

    /// Nil when there's no session window. A session whose reset time has passed reads as fresh (0%).
    public init?(window: LimitWindow?, now: Date, policy: PacingPolicy = .standard) {
        guard let window, window.kind == .session else { return nil }
        var used = window.used
        if let resetsAt = window.resetsAt, resetsAt <= now { used = 0 }
        self.init(
            level: SessionLevel(used: used, policy: policy),
            used: used,
            resetsAt: window.resetsAt,
            countdown: window.resetsAt.map { max(0, $0.timeIntervalSince(now)) }
        )
    }

    /// Banner title.
    public var title: String {
        switch level {
        case .blocked: "5-hour limit reached"
        case .rose, .amber: "5-hour session almost used"
        case .normal: "5-hour session"
        }
    }
}
