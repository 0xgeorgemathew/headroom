import Foundation
import Testing
@testable import HeadroomKit

@Suite("TimeFormat")
struct TimeFormatTests {
    let cal = PT.calendar
    let loc = PT.locale
    let now = PT.date(2026, 10, 20, 10, 2) // Tuesday

    @Test func compact() {
        #expect(TimeFormat.compact(20) == "<1m")
        #expect(TimeFormat.compact(48 * 60) == "48m")
        #expect(TimeFormat.compact(19 * 3600 + 58 * 60) == "20h")
        #expect(TimeFormat.compact(47 * 3600) == "47h")
        #expect(TimeFormat.compact(4 * 86400 + 3 * 3600) == "4d")
        #expect(TimeFormat.compact(59 * 60 + 50) == "1h")
        #expect(TimeFormat.compact(-5) == "<1m")
    }

    @Test func countdown() {
        #expect(TimeFormat.countdown(48 * 60) == "48m")
        #expect(TimeFormat.countdown(72 * 60) == "1:12")
        #expect(TimeFormat.countdown(30) == "<1m")
        #expect(TimeFormat.countdown(60 * 60) == "1:00")
    }

    @Test func freshness() {
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-10), now: now) == "now")
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-125), now: now) == "2m")
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-3 * 3600 - 5), now: now) == "3h")
        #expect(TimeFormat.freshness(since: now.addingTimeInterval(-2 * 86400), now: now) == "2d")
    }

    @Test func spokenSpan() {
        #expect(TimeFormat.spokenSpan(21 * 3600) == "21 hours")
        #expect(TimeFormat.spokenSpan(3600) == "1 hour")
        #expect(TimeFormat.spokenSpan(45 * 60) == "45 minutes")
        #expect(TimeFormat.spokenSpan(4 * 86400) == "4 days")
    }

    @Test func clocks() {
        let six = PT.date(2026, 10, 21, 6, 0)
        let halfPast = PT.date(2026, 10, 20, 12, 30)
        #expect(TimeFormat.clock(six, calendar: cal, locale: loc) == "6:00 AM")
        #expect(TimeFormat.shortClock(six, calendar: cal, locale: loc) == "6 AM")
        #expect(TimeFormat.shortClock(halfPast, calendar: cal, locale: loc) == "12:30 PM")
        #expect(TimeFormat.weekdayShort(six, calendar: cal, locale: loc) == "Wed")
        #expect(TimeFormat.weekdayLong(six, calendar: cal, locale: loc) == "Wednesday")
        #expect(TimeFormat.monthDay(six, calendar: cal, locale: loc) == "Oct 21")
    }

    @Test func renewalCaption() {
        #expect(TimeFormat.renewalCaption(PT.date(2026, 10, 21, 6, 0), now: now, calendar: cal, locale: loc) == "renews Wed 6:00 AM")
        #expect(TimeFormat.renewalCaption(PT.date(2026, 10, 24, 13, 0), now: now, calendar: cal, locale: loc) == "renews Sat 1:00 PM")
        #expect(TimeFormat.renewalCaption(PT.date(2026, 11, 3, 13, 0), now: now, calendar: cal, locale: loc) == "renews Nov 3")
    }

    @Test func relative() {
        #expect(TimeFormat.relative(PT.date(2026, 10, 20, 12, 30), now: now, calendar: cal, locale: loc) == "today at 12:30 PM")
        #expect(TimeFormat.relative(PT.date(2026, 10, 21, 6, 0), now: now, calendar: cal, locale: loc) == "tomorrow at 6 AM")
        #expect(TimeFormat.relative(PT.date(2026, 10, 23, 16, 0), now: now, calendar: cal, locale: loc) == "Friday 4 PM")
        #expect(TimeFormat.relative(PT.date(2026, 10, 30, 16, 0), now: now, calendar: cal, locale: loc) == "Oct 30 at 4 PM")
    }

    @Test func resets() {
        #expect(TimeFormat.resets(PT.date(2026, 10, 20, 12, 30), now: now, calendar: cal, locale: loc) == "resets 12:30 PM")
        #expect(TimeFormat.resets(PT.date(2026, 10, 22, 12, 30), now: now, calendar: cal, locale: loc) == "resets Thu 12:30 PM")
    }

    @Test func dayOffsetAcrossMidnight() {
        let lateNight = PT.date(2026, 10, 20, 23, 50)
        #expect(TimeFormat.dayOffset(PT.date(2026, 10, 21, 0, 10), now: lateNight, calendar: cal) == 1)
        #expect(TimeFormat.dayOffset(lateNight, now: lateNight, calendar: cal) == 0)
    }
}
