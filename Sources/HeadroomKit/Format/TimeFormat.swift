import Foundation

/// Time and duration phrases used across the card, menu bar, CLI and shares.
/// Every function takes an explicit `now`, `Calendar` and `Locale` so output is deterministic in tests.
public enum TimeFormat {
    // MARK: Durations

    /// Compact duration: "<1m", "48m", "20h", "4d".
    /// Minutes under an hour, rounded hours under 47.5 h, whole days after that.
    public static func compact(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "<1m" }
        if s < 3600 - 30 { return "\(Int((s / 60).rounded()))m" }
        if s < 47.5 * 3600 { return "\(max(1, Int((s / 3600).rounded())))h" }
        return "\(Int(s / 86400))d"
    }

    /// Countdown to a reset: "48m" under an hour, then "h:mm" ("1:12").
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "<1m" }
        let totalMinutes = Int((s / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    /// Age of a reading: "now", "2m", "3h", "2d".
    public static func freshness(since date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// Spoken span for "21 hours early": "45 minutes", "1 hour", "21 hours", "3 days".
    public static func spokenSpan(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 - 30 {
            let m = max(1, Int((s / 60).rounded()))
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        if s < 72 * 3600 {
            let h = max(1, Int((s / 3600).rounded()))
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        let d = Int((s / 86400).rounded())
        return "\(d) days"
    }

    // MARK: Clock and day words

    /// "6:00 AM", "12:30 PM" (locale's 12/24 h preference).
    public static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        clean(date.formatted(style(calendar, locale).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)))
    }

    /// "6 AM" on the hour, otherwise "6:30 AM".
    public static func shortClock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.component(.minute, from: date) == 0 {
            return clean(date.formatted(style(calendar, locale).hour(.defaultDigits(amPM: .abbreviated))))
        }
        return clock(date, calendar: calendar, locale: locale)
    }

    /// "Wed"
    public static func weekdayShort(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        clean(date.formatted(style(calendar, locale).weekday(.abbreviated)))
    }

    /// "Friday"
    public static func weekdayLong(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        clean(date.formatted(style(calendar, locale).weekday(.wide)))
    }

    /// "Oct 22"
    public static func monthDay(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        clean(date.formatted(style(calendar, locale).month(.abbreviated).day()))
    }

    /// Whole calendar days from `now` to `date` (0 = today, 1 = tomorrow, −1 = yesterday).
    public static func dayOffset(_ date: Date, now: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: now)
        let b = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // MARK: Phrases

    /// "renews Wed 6:00 AM", or "renews Oct 22" a week or more away.
    public static func renewalCaption(_ resetsAt: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        "renews " + dayAndClock(resetsAt, now: now, calendar: calendar, locale: locale)
    }

    /// "Wed 6:00 AM" within six days, otherwise "Oct 22".
    public static func dayAndClock(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let offset = dayOffset(date, now: now, calendar: calendar)
        if offset >= 7 || offset < 0 { return monthDay(date, calendar: calendar, locale: locale) }
        return weekdayShort(date, calendar: calendar, locale: locale) + " " + clock(date, calendar: calendar, locale: locale)
    }

    /// "today at 12:30 PM", "tomorrow at 6 AM", "Friday 4 PM", "Oct 22 at 4 PM".
    public static func relative(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = shortClock(date, calendar: calendar, locale: locale)
        switch dayOffset(date, now: now, calendar: calendar) {
        case 0: return "today at " + time
        case 1: return "tomorrow at " + time
        case 2...6: return weekdayLong(date, calendar: calendar, locale: locale) + " " + time
        default: return monthDay(date, calendar: calendar, locale: locale) + " at " + time
        }
    }

    /// "Wed 6 PM" style used inside sentences ("you run out Wed 6 PM"); "today 6 PM" / "tomorrow 6 PM" nearby.
    public static func shortDayTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = shortClock(date, calendar: calendar, locale: locale)
        switch dayOffset(date, now: now, calendar: calendar) {
        case 0: return "today " + time
        case 1: return "tomorrow " + time
        case 2...6: return weekdayShort(date, calendar: calendar, locale: locale) + " " + time
        default: return monthDay(date, calendar: calendar, locale: locale) + " " + time
        }
    }

    /// "resets 12:30 PM" today, "resets Wed 12:30 PM" later in the week.
    public static func resets(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if dayOffset(date, now: now, calendar: calendar) == 0 {
            return "resets " + clock(date, calendar: calendar, locale: locale)
        }
        return "resets " + dayAndClock(date, now: now, calendar: calendar, locale: locale)
    }

    /// "Friday 4 PM" within the week, "today 4 PM" / "tomorrow 4 PM" nearby, "Oct 22 4 PM" further out.
    public static func weekdayOrDay(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = shortClock(date, calendar: calendar, locale: locale)
        switch dayOffset(date, now: now, calendar: calendar) {
        case 0: return "today " + time
        case 1: return "tomorrow " + time
        case 2...6: return weekdayLong(date, calendar: calendar, locale: locale) + " " + time
        default: return monthDay(date, calendar: calendar, locale: locale) + " " + time
        }
    }

    // MARK: Private

    private static func style(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    /// ICU emits a narrow no-break space before AM/PM; the design uses a plain space.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
