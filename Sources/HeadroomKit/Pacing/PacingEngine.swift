import Foundation

/// One point of a window's glide history: how much was used at a moment.
public struct UsageSample: Codable, Sendable, Hashable {
    public var time: Date
    public var used: Double

    public init(time: Date, used: Double) {
        self.time = time
        self.used = used
    }
}

/// Which rule decided the state, so the verdict sentence can explain it.
public enum PacingRule: String, Codable, Sendable, Hashable {
    /// The sustainable multiple S decided it.
    case sustainable
    /// The last-24h projection escalated it to Getting tight.
    case projection
    /// The window is fully used.
    case exhausted
}

/// The pacing picture for one window at one moment (PLAN §2.1).
public struct PacingAnalysis: Codable, Sendable, Hashable {
    public var windowStart: Date
    public var resetsAt: Date
    public var duration: TimeInterval
    public var now: Date
    /// t: elapsed fraction of the window, 0…1.
    public var elapsed: Double
    /// τ: remaining time fraction, 0…1.
    public var timeFraction: Double
    /// r: remaining allowance fraction, 0…1.
    public var remaining: Double
    /// S = r ÷ τ. `.infinity` in the last hour while anything remains.
    public var multiple: Double
    public var timeLeft: TimeInterval
    /// State from S alone.
    public var rawState: PacingState
    /// State after the projection escalation (never lower than `rawState`).
    public var state: PacingState
    public var rule: PacingRule
    /// Last-24h burn rate in used-fraction per hour. Nil with under an hour of history.
    public var burnPerHour: Double?
    /// When the allowance runs out at the last-24h burn rate. Nil when the burn is zero or unknown.
    public var projectedRunOut: Date?
    /// Fraction left at renewal at the last-24h burn rate (0 when it runs out first).
    public var projectedUnusedAtReset: Double?
    /// When the allowance runs out at exactly even pace (1/W per hour).
    public var evenRunOut: Date
    /// Lit meter cells: round(r·5), at least 1 while anything remains.
    public var cells: Int
    /// Plenty available with renewal under 48 h: "use it before it resets".
    public var hourglass: Bool
    /// Where even pace would put the meter: τ, as a fraction of the track.
    public var evenPaceMarker: Double

    public var isMonthly: Bool { duration >= PacingPolicy.standard.monthlyWindow }

    /// Burn the user must hold to land exactly at zero on renewal, per hour.
    public var requiredBurnPerHour: Double {
        timeLeft > 0 ? remaining / (timeLeft / 3600) : .infinity
    }
}

public enum PacingEngine {
    /// Lit cells for a remaining fraction (PLAN §2.4).
    public static func cells(remaining r: Double) -> Int {
        guard r > 0 else { return 0 }
        return min(5, max(1, Int((r * 5).rounded())))
    }

    public static func analyze(
        window: LimitWindow,
        samples: [UsageSample],
        now: Date,
        policy: PacingPolicy = .standard
    ) -> PacingAnalysis {
        let duration = window.effectiveDuration
        let resetsAt = window.resetsAt ?? now.addingTimeInterval(duration)
        let windowStart = resetsAt.addingTimeInterval(-duration)
        let elapsed = min(max(now.timeIntervalSince(windowStart) / duration, 0), 1)
        let tau = 1 - elapsed
        let used = window.used
        let r = 1 - used
        let timeLeft = max(0, resetsAt.timeIntervalSince(now))

        let s: Double
        if timeLeft < policy.lastHour {
            s = r > 0 ? .infinity : 0
        } else {
            s = r / tau
        }

        let burn = burnRate(samples: samples, currentUsed: used, windowStart: windowStart, now: now, policy: policy)
        var projectedRunOut: Date?
        var unused: Double?
        if let burn {
            if r <= 0 {
                projectedRunOut = now
            } else if burn > 0 {
                projectedRunOut = now.addingTimeInterval(r / burn * 3600)
            }
            unused = max(0, r - burn * timeLeft / 3600)
        }

        let raw: PacingState
        let rule: PacingRule
        var state: PacingState
        if used >= 1 {
            raw = .veryTight
            state = .veryTight
            rule = .exhausted
        } else {
            raw = policy.classify(multiple: s, remaining: r)
            state = raw
            var fired = false
            if let runOut = projectedRunOut, runOut < resetsAt.addingTimeInterval(-policy.projectionMargin(timeLeft: timeLeft)) {
                fired = true
                state = max(raw, .tight)
            }
            // The projection's sentence wins whenever it fired and S alone did not already say "very tight".
            rule = fired && raw <= .tight ? .projection : .sustainable
        }

        return PacingAnalysis(
            windowStart: windowStart,
            resetsAt: resetsAt,
            duration: duration,
            now: now,
            elapsed: elapsed,
            timeFraction: tau,
            remaining: r,
            multiple: s,
            timeLeft: timeLeft,
            rawState: raw,
            state: state,
            rule: rule,
            burnPerHour: burn,
            projectedRunOut: projectedRunOut,
            projectedUnusedAtReset: unused,
            evenRunOut: now.addingTimeInterval(max(0, r) * duration),
            cells: cells(remaining: r),
            hourglass: state == .plenty && timeLeft < policy.hourglassHorizon,
            evenPaceMarker: tau
        )
    }

    /// Used-fraction per hour over the last 24 h (or since the window began, if later).
    /// History before Headroom was installed is never invented: with under an hour of it, nil.
    public static func burnRate(
        samples: [UsageSample],
        currentUsed: Double,
        windowStart: Date,
        now: Date,
        policy: PacingPolicy = .standard
    ) -> Double? {
        let lookbackStart = now.addingTimeInterval(-policy.projectionLookback)
        let base: (time: Date, used: Double)
        if windowStart >= lookbackStart {
            base = (windowStart, 0)
        } else {
            let inWindow = samples
                .filter { $0.time >= windowStart && $0.time <= now }
                .sorted { $0.time < $1.time }
            guard let first = inWindow.first else { return nil }
            if first.time >= lookbackStart {
                base = (first.time, first.used)
            } else {
                // Interpolate the used fraction at the lookback start.
                let before = inWindow.last { $0.time <= lookbackStart } ?? first
                let after = inWindow.first { $0.time > lookbackStart }
                if let after, after.time > before.time {
                    let f = lookbackStart.timeIntervalSince(before.time) / after.time.timeIntervalSince(before.time)
                    base = (lookbackStart, before.used + (after.used - before.used) * f)
                } else {
                    base = (lookbackStart, before.used)
                }
            }
        }
        let span = now.timeIntervalSince(base.time)
        guard span >= policy.projectionMinHistory else { return nil }
        return max(0, currentUsed - base.used) / (span / 3600)
    }
}
