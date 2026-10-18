import Foundation
import Testing
@testable import HeadroomKit

@Suite("PacingEngine")
struct PacingEngineTests {
    // Mockup scenario: Tue 10:02, Claude renews Wed 6:00 AM with 82% left.
    let now = PT.date(2026, 10, 20, 10, 2)

    @Test func claudeMockupIsPlentyWithHourglass() {
        let reset = PT.date(2026, 10, 21, 6, 0)
        let start = reset.addingTimeInterval(-PT.week)
        let samples = PT.linear(from: start, fromUsed: 0, to: now, toUsed: 0.18)
        let a = PacingEngine.analyze(window: PT.weekly(used: 0.18, resetsAt: reset), samples: samples, now: now)
        #expect(abs(a.multiple - 6.9) < 0.05)
        #expect(a.rawState == .plenty)
        #expect(a.state == .plenty)
        #expect(a.rule == .sustainable)
        #expect(a.cells == 4)
        #expect(a.hourglass)
        #expect(abs(a.evenPaceMarker - 0.119) < 0.002)
        let unused = try! #require(a.projectedUnusedAtReset)
        #expect(abs(unused - 0.80) < 0.01)
    }

    // Codex mockup: renews Sat 1 PM with 59% left; today's burn runs out Fri 4 PM.
    @Test func codexMockupEscalatesByProjection() {
        let reset = PT.date(2026, 10, 24, 13, 0)
        let runOut = PT.date(2026, 10, 23, 16, 0)
        let burn = 0.59 / (runOut.timeIntervalSince(now) / 3600)
        let samples = PT.linear(from: now.addingTimeInterval(-30 * 3600), fromUsed: 0.41 - burn * 30, to: now, toUsed: 0.41)
        let a = PacingEngine.analyze(window: PT.weekly(used: 0.41, resetsAt: reset), samples: samples, now: now)
        #expect(abs(a.multiple - 1.0) < 0.02)
        #expect(a.rawState == .onPace)
        #expect(a.state == .tight)
        #expect(a.rule == .projection)
        #expect(a.cells == 3)
        #expect(!a.hourglass)
        let projected = try! #require(a.projectedRunOut)
        #expect(abs(projected.timeIntervalSince(runOut)) < 120)
    }

    @Test func thresholds() {
        let p = PacingPolicy.standard
        #expect(p.classify(multiple: 2.0, remaining: 0.2) == .plenty)
        #expect(p.classify(multiple: 2.0, remaining: 0.19) == .onPace)
        #expect(p.classify(multiple: 1.99, remaining: 0.9) == .onPace)
        #expect(p.classify(multiple: 1.0, remaining: 0.5) == .onPace)
        #expect(p.classify(multiple: 0.99, remaining: 0.5) == .tight)
        #expect(p.classify(multiple: 0.75, remaining: 0.5) == .tight)
        #expect(p.classify(multiple: 0.74, remaining: 0.5) == .veryTight)
    }

    @Test func noAbsoluteFloor() {
        // 3% left with 2 h to go is on pace.
        let reset = now.addingTimeInterval(2 * 3600)
        let a = PacingEngine.analyze(window: PT.weekly(used: 0.97, resetsAt: reset), samples: [], now: now)
        #expect(a.state == .onPace)
    }

    @Test func firstHoursCanBeVeryTight() {
        // 30% used in the first 3 hours: S ≈ 0.71.
        let start = now.addingTimeInterval(-3 * 3600)
        let a = PacingEngine.analyze(window: PT.weekly(used: 0.30, resetsAt: start.addingTimeInterval(PT.week)), samples: [], now: now)
        #expect(abs(a.multiple - 0.71) < 0.01)
        #expect(a.state == .veryTight)
    }

    @Test func edgeAtStartOfWindow() {
        let a = PacingEngine.analyze(window: PT.weekly(used: 0, resetsAt: now.addingTimeInterval(PT.week)), samples: [], now: now)
        #expect(a.elapsed == 0)
        #expect(a.timeFraction == 1)
        #expect(a.multiple == 1)
        #expect(a.cells == 5)
        #expect(a.burnPerHour == nil)
    }

    @Test func lastHourIsInfiniteOrZero() {
        let reset = now.addingTimeInterval(1800)
        let left = PacingEngine.analyze(window: PT.weekly(used: 0.6, resetsAt: reset), samples: [], now: now)
        #expect(left.multiple == .infinity)
        #expect(left.state == .plenty)
        let none = PacingEngine.analyze(window: PT.weekly(used: 1.0, resetsAt: reset), samples: [], now: now)
        #expect(none.multiple == 0)
        #expect(none.rule == .exhausted)
        #expect(none.cells == 0)
        let past = PacingEngine.analyze(window: PT.weekly(used: 0.6, resetsAt: now.addingTimeInterval(-60)), samples: [], now: now)
        #expect(past.timeLeft == 0)
        #expect(past.multiple == .infinity)
    }

    @Test func cellsRoundAndKeepOneWhileAnythingRemains() {
        #expect(PacingEngine.cells(remaining: 0.82) == 4)
        #expect(PacingEngine.cells(remaining: 0.59) == 3)
        #expect(PacingEngine.cells(remaining: 0.03) == 1)
        #expect(PacingEngine.cells(remaining: 0) == 0)
        #expect(PacingEngine.cells(remaining: 1) == 5)
        #expect(PacingEngine.cells(remaining: 0.9) == 5)
    }

    @Test func burnUsesWindowStartWhenRecent() {
        // Window began 10 h ago with 0%; now 20% used → 2%/h even with no samples.
        let start = now.addingTimeInterval(-10 * 3600)
        let rate = PacingEngine.burnRate(samples: [], currentUsed: 0.2, windowStart: start, now: now)
        #expect(abs((rate ?? 0) - 0.02) < 1e-9)
    }

    @Test func burnNeedsAnHourOfHistory() {
        let start = now.addingTimeInterval(-3 * 86400)
        let samples = [UsageSample(time: now.addingTimeInterval(-1800), used: 0.4)]
        #expect(PacingEngine.burnRate(samples: samples, currentUsed: 0.45, windowStart: start, now: now) == nil)
        let more = [UsageSample(time: now.addingTimeInterval(-7200), used: 0.4)]
        #expect(abs((PacingEngine.burnRate(samples: more, currentUsed: 0.45, windowStart: start, now: now) ?? 0) - 0.025) < 1e-9)
    }

    @Test func burnInterpolatesAtLookbackStart() {
        let start = now.addingTimeInterval(-5 * 86400)
        let samples = [
            UsageSample(time: now.addingTimeInterval(-48 * 3600), used: 0.2),
            UsageSample(time: now.addingTimeInterval(-12 * 3600), used: 0.5),
        ]
        // At −24 h: 0.2 + 0.3 × (24/36) = 0.4. Now 0.64 → 0.24 / 24 h.
        let rate = PacingEngine.burnRate(samples: samples, currentUsed: 0.64, windowStart: start, now: now)
        #expect(abs((rate ?? 0) - 0.01) < 1e-9)
    }

    @Test func samplesFromPreviousWindowAreIgnored() {
        let start = now.addingTimeInterval(-3 * 86400)
        let samples = [UsageSample(time: start.addingTimeInterval(-3600), used: 0.9)]
        #expect(PacingEngine.burnRate(samples: samples, currentUsed: 0.3, windowStart: start, now: now) == nil)
    }

    @Test func projectionMarginRespectsMinimum() {
        // Runs out 5 h early with 2 days left: inside the max(6 h, 10%·48 h = 4.8 h) margin → no escalation.
        let reset = now.addingTimeInterval(48 * 3600)
        let r = 0.3
        let burn = r / 43.0
        let samples = PT.linear(from: now.addingTimeInterval(-24 * 3600), fromUsed: 0.7 - burn * 24, to: now, toUsed: 0.7)
        let a = PacingEngine.analyze(window: PT.weekly(used: 0.7, resetsAt: reset), samples: samples, now: now)
        #expect(a.rawState == .onPace)
        #expect(a.state == .onPace)
        // 8 h early → escalates.
        let burn2 = r / 40.0
        let s2 = PT.linear(from: now.addingTimeInterval(-24 * 3600), fromUsed: 0.7 - burn2 * 24, to: now, toUsed: 0.7)
        let b = PacingEngine.analyze(window: PT.weekly(used: 0.7, resetsAt: reset), samples: s2, now: now)
        #expect(b.state == .tight)
        #expect(b.rule == .projection)
    }

    @Test func veryTightKeepsSustainableRuleEvenWhenProjectionFires() {
        let start = now.addingTimeInterval(-24 * 3600)
        let a = PacingEngine.analyze(window: PT.weekly(used: 0.6, resetsAt: start.addingTimeInterval(PT.week)), samples: [], now: now)
        #expect(a.state == .veryTight)
        #expect(a.rule == .sustainable)
    }

    @Test func missingResetFallsBackToFullWindow() {
        let w = LimitWindow(id: "weekly", kind: .weekly, used: 0.1, resetsAt: nil)
        let a = PacingEngine.analyze(window: w, samples: [], now: now)
        #expect(a.timeFraction == 1)
        #expect(a.resetsAt == now.addingTimeInterval(PT.week))
    }

    // MARK: Properties

    @Test func multipleIsMonotonicInRemainingAndTime() {
        var rng = PT.Rng(seed: 1)
        for _ in 0..<500 {
            let tau = Double.random(in: 0.02...1, using: &rng)
            let r1 = Double.random(in: 0...1, using: &rng)
            let r2 = Double.random(in: r1...1, using: &rng)
            let reset = now.addingTimeInterval(tau * PT.week)
            let a1 = PacingEngine.analyze(window: PT.weekly(used: 1 - r1, resetsAt: reset), samples: [], now: now)
            let a2 = PacingEngine.analyze(window: PT.weekly(used: 1 - r2, resetsAt: reset), samples: [], now: now)
            #expect(a2.multiple >= a1.multiple)
            // More time left (larger τ) never raises S for the same r.
            let tau2 = Double.random(in: tau...1, using: &rng)
            let a3 = PacingEngine.analyze(window: PT.weekly(used: 1 - r1, resetsAt: now.addingTimeInterval(tau2 * PT.week)), samples: [], now: now)
            #expect(a3.multiple <= a1.multiple + 1e-12)
        }
    }

    @Test func projectionNeverLowersTheState() {
        var rng = PT.Rng(seed: 2)
        for _ in 0..<500 {
            let tau = Double.random(in: 0.05...1, using: &rng)
            let used = Double.random(in: 0...0.99, using: &rng)
            let reset = now.addingTimeInterval(tau * PT.week)
            let burn = Double.random(in: 0...0.05, using: &rng)
            let samples = PT.linear(from: now.addingTimeInterval(-24 * 3600), fromUsed: max(0, used - burn * 24), to: now, toUsed: used)
            let a = PacingEngine.analyze(window: PT.weekly(used: used, resetsAt: reset), samples: samples, now: now)
            #expect(a.state >= a.rawState)
            #expect(a.state == a.rawState || a.state == .tight)
        }
    }
}
