import Foundation

/// The one verdict per provider: badge, S× chip, a primary sentence and a muted one (PLAN §2.2, §3.4).
public struct Verdict: Codable, Sendable, Hashable {
    public var state: PacingState
    /// Badge text: "Plenty available", "Getting tight", or "Limit reached".
    public var title: String
    /// "6.9×", or "—" when S is infinite (last hour).
    public var multipleText: String
    public var primary: String
    public var secondary: String

    public init(state: PacingState, title: String, multipleText: String, primary: String, secondary: String) {
        self.state = state
        self.title = title
        self.multipleText = multipleText
        self.primary = primary
        self.secondary = secondary
    }
}

public enum VerdictWriter {
    /// Builds the verdict. Pass `state` to describe a tracker-smoothed state; it defaults to the analysis.
    public static func verdict(
        for a: PacingAnalysis,
        window: LimitWindow,
        now: Date,
        calendar: Calendar,
        locale: Locale,
        state: PacingState? = nil
    ) -> Verdict {
        let state = state ?? a.state
        let period = a.isMonthly ? "month" : "week"
        let chip = multipleText(a.multiple)

        if a.rule == .exhausted {
            return Verdict(
                state: .veryTight,
                title: "Limit reached",
                multipleText: chip,
                primary: (a.isMonthly ? "Monthly" : "Weekly") + " limit reached.",
                secondary: "Back " + TimeFormat.dayAndClock(a.resetsAt, now: now, calendar: calendar, locale: locale) + "."
            )
        }

        let renewDay = reachPhrase(a.resetsAt, now: now, calendar: calendar, locale: locale)

        switch state {
        case .plenty:
            let primary = "Spend it before it renews " + TimeFormat.relative(a.resetsAt, now: now, calendar: calendar, locale: locale) + "."
            let secondary: String
            if let unused = a.projectedUnusedAtReset {
                secondary = "At today's pace, \(percent(unused)) renews unused."
            } else {
                secondary = "\(percent(a.remaining)) left with \(TimeFormat.spokenSpan(a.timeLeft)) to go."
            }
            return Verdict(state: state, title: state.title, multipleText: chip, primary: primary, secondary: secondary)

        case .onPace:
            return Verdict(
                state: state,
                title: state.title,
                multipleText: chip,
                primary: "Roughly on pace for the \(period).",
                secondary: "At this pace it lasts to renewal."
            )

        case .tight:
            if (a.rule == .projection || a.rawState < .tight), let runOut = a.projectedRunOut, let burn = a.burnPerHour, burn > 0 {
                let early = a.resetsAt.timeIntervalSince(runOut)
                let ease = easeOff(required: a.requiredBurnPerHour, current: burn)
                return Verdict(
                    state: state,
                    title: state.title,
                    multipleText: chip,
                    primary: "Runs out " + TimeFormat.weekdayOrDay(runOut, now: now, calendar: calendar, locale: locale) + " at today's pace.",
                    secondary: "\(TimeFormat.spokenSpan(early)) early · ease off ~\(ease)% to reach \(renewDay)."
                )
            }
            let early = a.resetsAt.timeIntervalSince(a.evenRunOut)
            guard early > 0 else {
                return Verdict(
                    state: state,
                    title: state.title,
                    multipleText: chip,
                    primary: "Just under even pace for the \(period).",
                    secondary: "Ease off a little to reach \(renewDay)."
                )
            }
            let ease = max(5, roundToFive((1 - a.multiple) * 100))
            return Verdict(
                state: state,
                title: state.title,
                multipleText: chip,
                primary: "Even pace runs out " + TimeFormat.shortDayTime(a.evenRunOut, now: now, calendar: calendar, locale: locale) + ", \(TimeFormat.spokenSpan(early)) early.",
                secondary: "Ease off about \(ease)% to reach \(renewDay)."
            )

        case .veryTight:
            let early = a.resetsAt.timeIntervalSince(a.evenRunOut)
            return Verdict(
                state: state,
                title: state.title,
                multipleText: chip,
                primary: "At even pace you run out " + TimeFormat.shortDayTime(a.evenRunOut, now: now, calendar: calendar, locale: locale) + ", \(TimeFormat.spokenSpan(early)) early.",
                secondary: "Slow to about \(fractionPhrase(a.multiple)) your usual pace."
            )
        }
    }

    /// "6.9×", "12×" from 10 up, "—" when infinite.
    public static func multipleText(_ s: Double) -> String {
        guard s.isFinite else { return "—" }
        if s >= 10 { return "\(Int(s.rounded()))×" }
        return String(format: "%.1f×", s)
    }

    /// "half", "a third of", "two-thirds of", "60% of".
    static func fractionPhrase(_ s: Double) -> String {
        let s = max(0, s)
        if abs(s - 0.5) <= 0.05 { return "half" }
        if abs(s - 1.0 / 3.0) <= 0.05 { return "a third of" }
        if abs(s - 2.0 / 3.0) <= 0.05 { return "two-thirds of" }
        return "\(max(5, roundToFive(s * 100)))% of"
    }

    static func easeOff(required: Double, current: Double) -> Int {
        guard current > 0, required.isFinite else { return 0 }
        return max(5, roundToFive((1 - required / current) * 100))
    }

    static func roundToFive(_ x: Double) -> Int {
        Int((x / 5).rounded()) * 5
    }

    static func percent(_ f: Double) -> String {
        "\(Int((max(0, min(1, f)) * 100).rounded()))%"
    }

    /// The renewal day for "to reach Saturday"; "renewal" when it renews today.
    static func reachPhrase(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let offset = TimeFormat.dayOffset(date, now: now, calendar: calendar)
        if offset == 0 { return "renewal" }
        if offset == 1 { return "tomorrow" }
        if offset <= 6 { return TimeFormat.weekdayLong(date, calendar: calendar, locale: locale) }
        return TimeFormat.monthDay(date, calendar: calendar, locale: locale)
    }
}
