import Foundation

/// Smooths successive analyses of one window so the state doesn't flicker (PLAN §2.2).
///
/// Rules:
/// - The S-based state changes only when S (and, for Plenty's floor, r) crosses the boundary
///   by `policy.hysteresis`, and only after the current state has been shown for `minimumDwell`.
/// - Exhaustion (used ≥ 100%) applies immediately: it can stop you working now.
/// - A projection escalation applies immediately (it only ever raises the state, and the warning
///   is time-sensitive); it is released only after it has stopped firing for `minimumDwell`.
/// - A new window (renewal time moved by more than a minute) starts fresh.
public struct PacingTracker: Codable, Sendable, Hashable {
    public private(set) var trackedState: PacingState?
    public private(set) var since: Date?
    public private(set) var projectionLastFired: Date?
    public private(set) var resetsAt: Date?
    public private(set) var shown: PacingState?
    public var policy: PacingPolicy

    public init(policy: PacingPolicy = .standard) {
        self.policy = policy
    }

    @discardableResult
    public mutating func update(_ a: PacingAnalysis, now: Date) -> PacingState {
        if let resetsAt, abs(resetsAt.timeIntervalSince(a.resetsAt)) > 60 {
            trackedState = nil
            since = nil
            projectionLastFired = nil
        }
        resetsAt = a.resetsAt

        if a.rule == .exhausted {
            trackedState = .veryTight
            since = now
            shown = .veryTight
            return .veryTight
        }

        if let current = trackedState, let since {
            let raw = a.rawState
            if raw != current, now.timeIntervalSince(since) >= policy.minimumDwell {
                let shifted: PacingState
                if raw < current {
                    // Easing: S must clear the boundary by the hysteresis margin.
                    shifted = policy.classify(multiple: a.multiple, remaining: a.remaining, sShift: -policy.hysteresis, rShift: -policy.hysteresis)
                    if shifted < current { move(to: shifted, now: now) }
                } else {
                    shifted = policy.classify(multiple: a.multiple, remaining: a.remaining, sShift: policy.hysteresis, rShift: policy.hysteresis)
                    if shifted > current { move(to: shifted, now: now) }
                }
            }
        } else {
            move(to: a.rawState, now: now)
        }

        if a.state > a.rawState { projectionLastFired = now }
        var result = trackedState ?? a.rawState
        if let fired = projectionLastFired, now.timeIntervalSince(fired) < policy.minimumDwell || fired == now {
            result = max(result, .tight)
        } else {
            projectionLastFired = nil
        }
        shown = result
        return result
    }

    private mutating func move(to state: PacingState, now: Date) {
        trackedState = state
        since = now
    }
}
