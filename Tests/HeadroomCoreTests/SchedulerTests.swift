import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

@Suite struct SchedulerTests {
    let t0 = Date(timeIntervalSince1970: 1_792_400_000)

    func ready() -> AdaptiveScheduler {
        var s = AdaptiveScheduler()
        s.recordLimitRead(.claude, at: t0, succeeded: true, retryAt: nil)
        s.recordLimitRead(.codex, at: t0, succeeded: true, retryAt: nil)
        s.recordStatusCheck(.claude, at: t0)
        s.recordStatusCheck(.codex, at: t0)
        return s
    }

    @Test func firstRunReadsEverything() {
        let s = AdaptiveScheduler()
        #expect(Set(s.due(at: t0)) == [.readLimits(.claude), .readLimits(.codex), .checkStatus(.claude), .checkStatus(.codex)])
    }

    @Test func idleCadenceIsFifteenMinutes() {
        let s = ready()
        #expect(s.due(at: t0.addingTimeInterval(899)).isEmpty)
        #expect(s.nextLimitRead(for: .claude, at: t0.addingTimeInterval(1)) == t0.addingTimeInterval(900))
        #expect(s.due(at: t0.addingTimeInterval(900)).contains(.readLimits(.claude)))
    }

    @Test func activeCadenceIsFiveMinutes() {
        var s = ready()
        s.logActivity(at: t0.addingTimeInterval(60))
        #expect(s.limitInterval(at: t0.addingTimeInterval(120)) == 300)
        #expect(s.due(at: t0.addingTimeInterval(300)).contains(.readLimits(.claude)))
        // Ten quiet minutes later the cadence relaxes again.
        #expect(s.limitInterval(at: t0.addingTimeInterval(60 + 601)) == 900)
    }

    @Test func pausedOnSleepAndLock() {
        var s = ready()
        s.sleep()
        #expect(s.nextDeadline(at: t0.addingTimeInterval(5000)) == nil)
        #expect(s.due(at: t0.addingTimeInterval(5000)).isEmpty)
        s.wake(at: t0.addingTimeInterval(5000))
        #expect(s.due(at: t0.addingTimeInterval(5000)).contains(.readLimits(.claude)))

        var l = ready()
        l.screenLocked()
        #expect(l.due(at: t0.addingTimeInterval(5000)).isEmpty)
        l.screenUnlocked(at: t0.addingTimeInterval(5000))
        #expect(l.due(at: t0.addingTimeInterval(5000)).contains(.readLimits(.codex)))
    }

    @Test func wakeFiresImmediatelyEvenIfRecent() {
        var s = ready()
        s.sleep()
        s.wake(at: t0.addingTimeInterval(30))
        #expect(s.due(at: t0.addingTimeInterval(30)).contains(.readLimits(.claude)))
        s.recordLimitRead(.claude, at: t0.addingTimeInterval(31), succeeded: true, retryAt: nil)
        #expect(!s.due(at: t0.addingTimeInterval(32)).contains(.readLimits(.claude)))
    }

    @Test func popoverOpenReadsStaleProvidersOnly() {
        var s = ready()
        s.recordLimitRead(.codex, at: t0.addingTimeInterval(100), succeeded: true, retryAt: nil)
        s.popoverOpened(at: t0.addingTimeInterval(130))
        let due = s.due(at: t0.addingTimeInterval(130))
        #expect(due.contains(.readLimits(.claude)))     // 130 s old
        #expect(!due.contains(.readLimits(.codex)))     // 30 s old
    }

    @Test func freshPassiveCodexReadingSkipsTheSpawn() {
        var s = ready()
        s.passiveCodexReading(at: t0.addingTimeInterval(800))
        #expect(s.codexPassiveIsFresh(at: t0.addingTimeInterval(900)))
        #expect(!s.due(at: t0.addingTimeInterval(900)).contains(.readLimits(.codex)))
        #expect(s.due(at: t0.addingTimeInterval(900)).contains(.readLimits(.claude)))
        #expect(s.nextLimitRead(for: .codex, at: t0.addingTimeInterval(900)) == t0.addingTimeInterval(800 + 900))
        // Even a popover open doesn't spawn while the passive reading is fresh.
        s.popoverOpened(at: t0.addingTimeInterval(1000))
        #expect(!s.due(at: t0.addingTimeInterval(1000)).contains(.readLimits(.codex)))
    }

    @Test func faultRetryOverridesCadenceAndTriggersStatus() {
        var s = ready()
        s.recordLimitRead(.claude, at: t0.addingTimeInterval(10), succeeded: false, retryAt: t0.addingTimeInterval(70))
        #expect(s.due(at: t0.addingTimeInterval(10)).contains(.checkStatus(.claude)))
        #expect(s.nextLimitRead(for: .claude, at: t0.addingTimeInterval(11)) == t0.addingTimeInterval(70))
        s.recordStatusCheck(.claude, at: t0.addingTimeInterval(11))
        #expect(s.due(at: t0.addingTimeInterval(70)) == [.readLimits(.claude)])
        // A long retry (enterprise: daily) suppresses the 15-minute cadence.
        s.recordLimitRead(.claude, at: t0.addingTimeInterval(70), succeeded: false, retryAt: t0.addingTimeInterval(86470))
        #expect(!s.due(at: t0.addingTimeInterval(5000)).contains(.readLimits(.claude)))
    }

    @Test func statusEveryFifteenMinutesWhenEnabled() {
        var s = ready()
        #expect(s.due(at: t0.addingTimeInterval(900)).contains(.checkStatus(.codex)))
        s.statusChecksEnabled = false
        #expect(!s.due(at: t0.addingTimeInterval(900)).contains(.checkStatus(.codex)))
    }

    @Test func disabledProviderNeverRuns() {
        var s = AdaptiveScheduler(enabled: [.claude])
        s.popoverOpened(at: t0)
        s.refreshNow()
        #expect(s.due(at: t0).allSatisfy { $0 != .readLimits(.codex) && $0 != .checkStatus(.codex) })
    }

    @Test func pathSatisfiedRetries() {
        var s = ready()
        s.recordLimitRead(.codex, at: t0, succeeded: false, retryAt: t0.addingTimeInterval(900))
        s.pathSatisfied(retrying: [.codex])
        #expect(s.due(at: t0.addingTimeInterval(5)).contains(.readLimits(.codex)))
    }

    @Test func leewayIsTenToTwentyPercent() {
        var s = AdaptiveScheduler()
        #expect(s.leeway(forDelay: 300) == 45)
        s.policy.leewayFraction = 0.5
        #expect(s.leeway(forDelay: 100) == 20)
        s.policy.leewayFraction = 0.01
        #expect(s.leeway(forDelay: 100) == 10)
    }

    @Test func nextDeadlineIsEarliest() {
        var s = ready()
        s.logActivity(at: t0)
        #expect(s.nextDeadline(at: t0.addingTimeInterval(1)) == t0.addingTimeInterval(300))
    }
}
