import Foundation
import Testing
@testable import HeadroomKit

@Suite("PacingTracker")
struct PacingTrackerTests {
    let t0 = PT.date(2026, 10, 20, 9, 0)
    let reset = PT.date(2026, 10, 24, 9, 0)

    /// Analysis for a target S at `now`, holding the reset fixed (so r = S·τ).
    func analysis(multiple s: Double, at now: Date, remainingOverride: Double? = nil) -> PacingAnalysis {
        let tau = reset.timeIntervalSince(now) / PT.week
        let r = remainingOverride ?? min(1, s * tau)
        return PacingEngine.analyze(window: PT.weekly(used: 1 - r, resetsAt: reset), samples: [], now: now)
    }

    @Test func noFlickerUnderNoiseAroundEveryBoundary() {
        var rng = PT.Rng(seed: 42)
        for boundary in [0.75, 1.0] {
            var tracker = PacingTracker()
            var changes = 0
            var last: PacingState?
            for step in 0..<400 {
                let now = t0.addingTimeInterval(Double(step) * 300)
                let s = boundary + Double.random(in: -0.04...0.04, using: &rng)
                let shown = tracker.update(analysis(multiple: s, at: now), now: now)
                if let last, last != shown { changes += 1 }
                last = shown
            }
            #expect(changes == 0, "boundary \(boundary) changed \(changes) times")
        }
    }

    @Test func noFlickerAtPlentyBoundaryInMultipleAndRemaining() {
        var rng = PT.Rng(seed: 7)
        var tracker = PacingTracker()
        var changes = 0
        var last: PacingState?
        for step in 0..<400 {
            let now = t0.addingTimeInterval(Double(step) * 300)
            let tau = reset.timeIntervalSince(now) / PT.week
            let s = 2.0 + Double.random(in: -0.04...0.04, using: &rng)
            let a = analysis(multiple: s, at: now, remainingOverride: min(1, s * tau))
            let shown = tracker.update(a, now: now)
            if let last, last != shown { changes += 1 }
            last = shown
        }
        #expect(changes == 0)

        // Remaining hovering at the 20% floor with a large S.
        var t2 = PacingTracker()
        changes = 0
        last = nil
        let lateReset = t0.addingTimeInterval(20 * 3600)
        for step in 0..<200 {
            let now = t0.addingTimeInterval(Double(step) * 60)
            let r = 0.20 + Double.random(in: -0.04...0.04, using: &rng)
            let a = PacingEngine.analyze(window: PT.weekly(used: 1 - r, resetsAt: lateReset), samples: [], now: now)
            let shown = t2.update(a, now: now)
            if let last, last != shown { changes += 1 }
            last = shown
        }
        #expect(changes == 0)
    }

    @Test func changesAfterClearCrossingAndDwell() {
        var tracker = PacingTracker()
        #expect(tracker.update(analysis(multiple: 1.2, at: t0), now: t0) == .onPace)
        // Clear drop to S 0.9 two minutes later: held by the dwell.
        let t1 = t0.addingTimeInterval(120)
        #expect(tracker.update(analysis(multiple: 0.9, at: t1), now: t1) == .onPace)
        // After 10 minutes it moves.
        let t2 = t0.addingTimeInterval(660)
        #expect(tracker.update(analysis(multiple: 0.9, at: t2), now: t2) == .tight)
        // A small recovery to 1.03 (inside the hysteresis band) holds tight.
        let t3 = t2.addingTimeInterval(1200)
        #expect(tracker.update(analysis(multiple: 1.03, at: t3), now: t3) == .tight)
        // 1.06 clears the band.
        let t4 = t3.addingTimeInterval(60)
        #expect(tracker.update(analysis(multiple: 1.06, at: t4), now: t4) == .onPace)
    }

    @Test func exhaustionAppliesImmediately() {
        var tracker = PacingTracker()
        #expect(tracker.update(analysis(multiple: 1.5, at: t0), now: t0) == .onPace)
        let t1 = t0.addingTimeInterval(30)
        let a = PacingEngine.analyze(window: PT.weekly(used: 1, resetsAt: reset), samples: [], now: t1)
        #expect(tracker.update(a, now: t1) == .veryTight)
    }

    @Test func projectionEscalatesImmediatelyAndReleasesAfterDwell() {
        var tracker = PacingTracker()
        #expect(tracker.update(analysis(multiple: 1.5, at: t0), now: t0) == .onPace)
        let t1 = t0.addingTimeInterval(60)
        var escalated = analysis(multiple: 1.5, at: t1)
        escalated.state = .tight
        escalated.rule = .projection
        #expect(tracker.update(escalated, now: t1) == .tight)
        let t2 = t1.addingTimeInterval(120)
        #expect(tracker.update(analysis(multiple: 1.5, at: t2), now: t2) == .tight)
        let t3 = t1.addingTimeInterval(700)
        #expect(tracker.update(analysis(multiple: 1.5, at: t3), now: t3) == .onPace)
    }

    @Test func newWindowStartsFresh() {
        var tracker = PacingTracker()
        #expect(tracker.update(analysis(multiple: 0.5, at: t0), now: t0) == .veryTight)
        let t1 = t0.addingTimeInterval(60)
        let fresh = PacingEngine.analyze(window: PT.weekly(used: 0, resetsAt: t1.addingTimeInterval(PT.week)), samples: [], now: t1)
        #expect(tracker.update(fresh, now: t1) == .onPace)
    }

    @Test func codableRoundTrip() throws {
        var tracker = PacingTracker()
        tracker.update(analysis(multiple: 1.2, at: t0), now: t0)
        let data = try JSONEncoder().encode(tracker)
        let back = try JSONDecoder().decode(PacingTracker.self, from: data)
        #expect(back == tracker)
    }
}
