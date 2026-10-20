import Foundation

/// Every pacing threshold in one place (PLAN §2.2, §2.3). Changing a threshold is a one-line edit.
public struct PacingPolicy: Codable, Sendable, Hashable {
    /// Plenty available: S at or above this…
    public var plentyMultiple: Double = 2.0
    /// …and at least this much of the window remaining.
    public var plentyMinRemaining: Double = 0.20
    /// On pace: S at or above this (and below plenty).
    public var onPaceMultiple: Double = 1.0
    /// Getting tight: S at or above this (and below on pace). Below it is very tight.
    public var tightMultiple: Double = 0.75
    /// A state only changes once S (or r, for plenty's floor) crosses its boundary by this much.
    public var hysteresis: Double = 0.05
    /// A state, once shown, holds at least this long.
    public var minimumDwell: TimeInterval = 600
    /// The last-24h projection escalates to tight when it runs out more than
    /// max(`projectionMinMargin`, `projectionMarginFraction` × time left) before renewal.
    public var projectionMinMargin: TimeInterval = 6 * 3600
    public var projectionMarginFraction: Double = 0.10
    /// How far back the projection measures the burn rate.
    public var projectionLookback: TimeInterval = 24 * 3600
    /// The projection needs at least this much history.
    public var projectionMinHistory: TimeInterval = 3600
    /// Inside the last hour S is ∞ (or 0 when nothing is left).
    public var lastHour: TimeInterval = 3600
    /// 5-hour session warning levels.
    public var sessionAmber: Double = 0.75
    public var sessionRose: Double = 0.90
    public var sessionBlocked: Double = 1.0
    /// Hourglass: Plenty available and renewal closer than this.
    public var hourglassHorizon: TimeInterval = 48 * 3600
    /// Reset credits expiring within this window are highlighted.
    public var creditExpiryHighlight: TimeInterval = 7 * 86400
    /// Windows at least this long are described as a month rather than a week.
    public var monthlyWindow: TimeInterval = 28 * 86400

    public init() {}

    public static let standard = PacingPolicy()

    /// The standard policy with the 5-hour warning moved to `warnAt` (Settings). The rose level
    /// stays at 90% unless the warning itself starts there or later.
    public static func sessionWarning(at warnAt: Double) -> PacingPolicy {
        var p = PacingPolicy()
        p.sessionAmber = min(max(warnAt, 0.3), 0.95)
        p.sessionRose = max(0.90, min(p.sessionAmber + 0.05, 0.98))
        return p
    }

    /// Classifies by the sustainable multiple alone. `sShift` / `rShift` move the boundaries for hysteresis.
    public func classify(multiple s: Double, remaining r: Double, sShift: Double = 0, rShift: Double = 0) -> PacingState {
        let s = s + sShift
        if s >= plentyMultiple && r + rShift >= plentyMinRemaining { return .plenty }
        if s >= onPaceMultiple { return .onPace }
        if s >= tightMultiple { return .tight }
        return .veryTight
    }

    /// Margin by which a projected run-out must precede renewal to escalate.
    public func projectionMargin(timeLeft: TimeInterval) -> TimeInterval {
        max(projectionMinMargin, projectionMarginFraction * max(0, timeLeft))
    }
}
