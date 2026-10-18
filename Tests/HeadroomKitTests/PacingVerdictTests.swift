import Foundation
import Testing
@testable import HeadroomKit

@Suite("Verdict")
struct PacingVerdictTests {
    let now = PT.date(2026, 10, 20, 10, 2) // Tue

    func verdict(_ window: LimitWindow, _ samples: [UsageSample] = []) -> Verdict {
        let a = PacingEngine.analyze(window: window, samples: samples, now: now)
        return VerdictWriter.verdict(for: a, window: window, now: now, calendar: PT.calendar, locale: PT.locale)
    }

    @Test func plenty() {
        let reset = PT.date(2026, 10, 21, 6, 0)
        let samples = PT.linear(from: reset.addingTimeInterval(-PT.week), fromUsed: 0, to: now, toUsed: 0.18)
        let v = verdict(PT.weekly(used: 0.18, resetsAt: reset), samples)
        #expect(v.title == "Plenty available")
        #expect(v.multipleText == "6.9×")
        #expect(v.primary == "Spend it before it renews tomorrow at 6 AM.")
        #expect(v.secondary == "At today's pace, 80% renews unused.")
    }

    @Test func plentyWithoutHistory() {
        let reset = PT.date(2026, 10, 21, 6, 0)
        let v = verdict(PT.weekly(used: 0.18, resetsAt: reset))
        #expect(v.secondary == "82% left with 20 hours to go.")
    }

    @Test func onPace() {
        let reset = now.addingTimeInterval(PT.week / 2)
        let v = verdict(PT.weekly(used: 0.4, resetsAt: reset))
        #expect(v.title == "On pace")
        #expect(v.multipleText == "1.2×")
        #expect(v.primary == "Roughly on pace for the week.")
        #expect(v.secondary == "At this pace it lasts to renewal.")
    }

    @Test func tightByProjection() {
        let reset = PT.date(2026, 10, 24, 13, 0)
        let runOut = PT.date(2026, 10, 23, 16, 0)
        let burn = 0.59 / (runOut.timeIntervalSince(now) / 3600)
        let samples = PT.linear(from: now.addingTimeInterval(-30 * 3600), fromUsed: 0.41 - burn * 30, to: now, toUsed: 0.41)
        let v = verdict(PT.weekly(used: 0.41, resetsAt: reset), samples)
        #expect(v.title == "Getting tight")
        #expect(v.multipleText == "1.0×")
        #expect(v.primary == "Runs out Friday 4 PM at today's pace.")
        #expect(v.secondary == "21 hours early · ease off ~20% to reach Saturday.")
    }

    @Test func tightBySustainableMultiple() {
        // S = 0.9 with renewal Saturday 1 PM.
        let reset = PT.date(2026, 10, 24, 13, 0)
        let tau = reset.timeIntervalSince(now) / PT.week
        let v = verdict(PT.weekly(used: 1 - 0.9 * tau, resetsAt: reset))
        #expect(v.title == "Getting tight")
        #expect(v.multipleText == "0.9×")
        #expect(v.primary.hasPrefix("Even pace runs out "))
        #expect(v.primary.hasSuffix(" early."))
        #expect(v.secondary == "Ease off about 10% to reach Saturday.")
    }

    @Test func veryTight() {
        // Wed 6 PM run-out at even pace, 15 hours before Thu 9 AM renewal.
        let reset = PT.date(2026, 10, 22, 9, 0)
        let runOut = PT.date(2026, 10, 21, 18, 0)
        let r = runOut.timeIntervalSince(now) / PT.week
        let v = verdict(PT.weekly(used: 1 - r, resetsAt: reset))
        #expect(v.title == "Very tight")
        #expect(v.primary == "At even pace you run out tomorrow 6 PM, 15 hours early.")
        #expect(v.secondary.hasPrefix("Slow to about "))
        #expect(v.secondary.hasSuffix(" your usual pace."))
    }

    @Test func veryTightLaterInWeekUsesWeekday() {
        let now = PT.date(2026, 10, 19, 10, 0) // Mon
        let reset = PT.date(2026, 10, 22, 14, 0) // Thu 2 PM
        let runOut = PT.date(2026, 10, 21, 18, 0) // Wed 6 PM
        let r = runOut.timeIntervalSince(now) / PT.week
        let w = PT.weekly(used: 1 - r, resetsAt: reset)
        let a = PacingEngine.analyze(window: w, samples: [], now: now)
        let v = VerdictWriter.verdict(for: a, window: w, now: now, calendar: PT.calendar, locale: PT.locale)
        #expect(a.state == .veryTight)
        #expect(v.primary == "At even pace you run out Wed 6 PM, 20 hours early.")
        #expect(v.secondary == "Slow to about 75% of your usual pace.")
    }

    @Test func veryTightAtHalfPace() {
        let now = PT.date(2026, 10, 21, 3, 0) // Wed 3 AM
        let reset = PT.date(2026, 10, 22, 9, 0)
        let runOut = PT.date(2026, 10, 21, 18, 0)
        let r = runOut.timeIntervalSince(now) / PT.week
        let w = PT.weekly(used: 1 - r, resetsAt: reset)
        let a = PacingEngine.analyze(window: w, samples: [], now: now)
        let v = VerdictWriter.verdict(for: a, window: w, now: now, calendar: PT.calendar, locale: PT.locale)
        #expect(abs(a.multiple - 0.5) < 0.01)
        #expect(v.primary == "At even pace you run out today 6 PM, 15 hours early.")
        #expect(v.secondary == "Slow to about half your usual pace.")
    }

    @Test func fractionWords() {
        #expect(VerdictWriter.fractionPhrase(0.5) == "half")
        #expect(VerdictWriter.fractionPhrase(0.34) == "a third of")
        #expect(VerdictWriter.fractionPhrase(0.66) == "two-thirds of")
        #expect(VerdictWriter.fractionPhrase(0.6) == "60% of")
        #expect(VerdictWriter.fractionPhrase(0.02) == "5% of")
    }

    @Test func exhausted() {
        let reset = PT.date(2026, 10, 21, 6, 0)
        let v = verdict(PT.weekly(used: 1, resetsAt: reset))
        #expect(v.title == "Limit reached")
        #expect(v.primary == "Weekly limit reached.")
        #expect(v.secondary == "Back Wed 6:00 AM.")
    }

    @Test func monthlyWindowSaysMonth() {
        let month: TimeInterval = 30 * 86400
        let reset = now.addingTimeInterval(month / 2)
        let v = verdict(PT.weekly(used: 0.4, resetsAt: reset, duration: month))
        #expect(v.primary == "Roughly on pace for the month.")
        let ex = verdict(PT.weekly(used: 1, resetsAt: reset, duration: month))
        #expect(ex.primary == "Monthly limit reached.")
        #expect(ex.secondary == "Back Nov 4.")
    }

    @Test func infiniteMultipleShowsDash() {
        #expect(VerdictWriter.multipleText(.infinity) == "—")
        #expect(VerdictWriter.multipleText(12.4) == "12×")
        #expect(VerdictWriter.multipleText(0.6) == "0.6×")
    }

    @Test func trackerStateOverridesAnalysis() {
        let reset = now.addingTimeInterval(PT.week / 2)
        let w = PT.weekly(used: 0.4, resetsAt: reset)
        let a = PacingEngine.analyze(window: w, samples: [], now: now)
        let v = VerdictWriter.verdict(for: a, window: w, now: now, calendar: PT.calendar, locale: PT.locale, state: .tight)
        #expect(v.state == .tight)
        #expect(v.title == "Getting tight")
    }
}
