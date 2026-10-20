import Foundation
import Testing
@testable import HeadroomKit

@Suite struct SessionForecastTests {
    let now = PT.date(2026, 10, 20, 10)

    func session(used: Double, resetsIn hours: Double) -> LimitWindow {
        LimitWindow(id: "session", kind: .session, used: used, resetsAt: now.addingTimeInterval(hours * 3600), duration: 5 * 3600)
    }

    @Test func idleWithoutUseOrAfterTheReset() {
        #expect(SessionForecast(window: nil, samples: [], now: now).outlook == .idle)
        #expect(SessionForecast(window: session(used: 0, resetsIn: 3), samples: [], now: now).outlook == .idle)
        #expect(SessionForecast(window: session(used: 0.6, resetsIn: -0.1), samples: [], now: now).outlook == .idle)
    }

    @Test func averageBurnProjectsARunOutBeforeTheReset() {
        // 2 h in, 60% used: 30%/h runs out in 80 min, well before the 3 h reset.
        let f = SessionForecast(window: session(used: 0.6, resetsIn: 3), samples: [], now: now)
        #expect(f.outlook == .runsOut)
        #expect(abs(f.burnPerHour! - 0.3) < 1e-9)
        #expect(abs(f.runsOutAt!.timeIntervalSince(now) - 80 * 60) < 1)
        #expect(f.leftAtReset == 0)
        #expect(f.pacingState == .tight)
    }

    @Test func comfortableWhenAQuarterIsLeftAtTheReset() {
        // 4 h in, 40% used: 10%/h leaves 50% at the reset in 1 h.
        let f = SessionForecast(window: session(used: 0.4, resetsIn: 1), samples: [], now: now)
        #expect(f.outlook == .comfortable)
        #expect(abs(f.leftAtReset! - 0.5) < 1e-9)
        #expect(f.pacingState == .plenty)
    }

    @Test func recentBurnOutweighsAQuietStart() {
        // 3 h in at 45%, but 25% of it in the last half hour: 50%/h runs out in 66 min (2 h left).
        let start = now.addingTimeInterval(-3 * 3600)
        let samples = [UsageSample(time: start.addingTimeInterval(600), used: 0.05),
                       UsageSample(time: now.addingTimeInterval(-1800), used: 0.20),
                       UsageSample(time: now, used: 0.45)]
        let f = SessionForecast(window: session(used: 0.45, resetsIn: 2), samples: samples, now: now)
        #expect(f.outlook == .runsOut)
        #expect(abs(f.burnPerHour! - 0.5) < 1e-9)
    }

    @Test func aPauseStillCountsHalfTheAverage() {
        let start = now.addingTimeInterval(-4 * 3600)
        let samples = [UsageSample(time: start.addingTimeInterval(1800), used: 0.7), UsageSample(time: now.addingTimeInterval(-3600), used: 0.8)]
        let f = SessionForecast(window: session(used: 0.8, resetsIn: 1), samples: samples, now: now)
        #expect(abs(f.burnPerHour! - 0.1) < 1e-9) // half of 0.8 / 4 h
        #expect(f.outlook == .lasts)
    }

    @Test func blockedAtTheLimit() {
        let f = SessionForecast(window: session(used: 1, resetsIn: 0.5), samples: [], now: now)
        #expect(f.outlook == .blocked)
        #expect(f.pacingState == .veryTight)
    }

    @Test func tooEarlyToTell() {
        let f = SessionForecast(window: session(used: 0.05, resetsIn: 4.95), samples: [], now: now)
        #expect(f.burnPerHour == nil)
        #expect(f.outlook == .comfortable)
    }

    @Test func warningThresholdMovesTheLevels() {
        let p = PacingPolicy.sessionWarning(at: 0.6)
        #expect(SessionLevel(used: 0.62, policy: p) == .amber)
        #expect(SessionLevel(used: 0.62) == .normal)
        #expect(SessionLevel(used: 0.91, policy: p) == .rose)
        let late = PacingPolicy.sessionWarning(at: 0.9)
        #expect(SessionLevel(used: 0.91, policy: late) == .amber)
        #expect(SessionLevel(used: 0.96, policy: late) == .rose)
    }
}
