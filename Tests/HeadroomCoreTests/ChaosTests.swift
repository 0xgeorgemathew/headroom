import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

/// Phase 6 chaos: sequences of failures through the client, fault machine and scheduler, checking
/// that the last good reading survives, the fault is named exactly, and the right retry fires.
@Suite struct ChaosTests {
    let t0 = date("2026-10-18T04:00:00Z")
    var usage: Data { Fixture.data("claude/usage-max-synthetic.json") }

    func creds(_ clock: FakeClock) -> StaticCredentials {
        StaticCredentials(credentials: [ClaudeCredentials(accessToken: "tok", expiresAt: clock.now.addingTimeInterval(3600), subscriptionType: "max", rateLimitTier: "default_claude_max_20x")])
    }

    func client(_ transport: FakeTransport, _ clock: FakeClock, credentials: (any ClaudeCredentialSource)? = nil) -> ClaudeUsageClient {
        ClaudeUsageClient(transport: transport, credentials: credentials ?? creds(clock), refresher: nil, clock: clock, accountKey: { "acct" })
    }

    @Test func offlineKeepsTheLastReadingAndRetriesWhenThePathReturns() async {
        let clock = FakeClock(t0)
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: usage)), .failure(.offline), .success(HTTPResponse(status: 200, body: usage))])
        let c = client(transport, clock)
        var machine = FaultMachine(provider: .claude)
        var scheduler = AdaptiveScheduler()

        machine.recordOutcome(await c.read(), at: clock.now)
        scheduler.recordLimitRead(.claude, at: clock.now, succeeded: true, retryAt: nil)
        let good = machine.lastGood
        #expect(good != nil && machine.fault == nil)

        clock.advance(900)
        machine.recordOutcome(await c.read(), at: clock.now)
        #expect(machine.fault == .offline)
        #expect(machine.lastGood == good)
        #expect(machine.lastGoodAge(at: clock.now) == 900)
        #expect(machine.retryPolicy?.onPathSatisfied == true)
        scheduler.recordLimitRead(.claude, at: clock.now, succeeded: false, retryAt: machine.nextRetryAt)

        scheduler.pathSatisfied(retrying: [.claude])
        #expect(scheduler.due(at: clock.now).contains(.readLimits(.claude)))
        machine.recordOutcome(await c.read(), at: clock.now)
        #expect(machine.fault == nil)
    }

    @Test func sleepPausesEverythingAndWakeReadsImmediately() {
        var scheduler = AdaptiveScheduler()
        for p in Provider.allCases { scheduler.recordLimitRead(p, at: t0, succeeded: true, retryAt: nil) }
        scheduler.recordStatusCheck(.claude, at: t0)
        scheduler.recordStatusCheck(.codex, at: t0)
        scheduler.sleep()
        #expect(scheduler.due(at: t0.addingTimeInterval(86400)).isEmpty)
        #expect(scheduler.nextDeadline(at: t0.addingTimeInterval(86400)) == nil)
        scheduler.wake(at: t0.addingTimeInterval(60))
        let due = scheduler.due(at: t0.addingTimeInterval(60))
        #expect(due.contains(.readLimits(.claude)) && due.contains(.readLimits(.codex)))
    }

    @Test func screenLockPausesAndUnlockCatchesUp() {
        var scheduler = AdaptiveScheduler()
        for p in Provider.allCases { scheduler.recordLimitRead(p, at: t0, succeeded: true, retryAt: nil) }
        scheduler.screenLocked()
        #expect(scheduler.due(at: t0.addingTimeInterval(3600)).isEmpty)
        scheduler.screenUnlocked(at: t0.addingTimeInterval(3600))
        #expect(scheduler.due(at: t0.addingTimeInterval(3600)).contains(.readLimits(.claude)))
    }

    @Test func keychainItemDisappearsThenReturns() async {
        let clock = FakeClock(t0)
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: usage)), .success(HTTPResponse(status: 200, body: usage))])
        var machine = FaultMachine(provider: .claude)
        machine.recordOutcome(await client(transport, clock).read(), at: clock.now)
        let good = machine.lastGood
        clock.advance(600)
        machine.recordOutcome(await client(transport, clock, credentials: StaticCredentials(credentials: [])).read(), at: clock.now)
        #expect(machine.fault == .signedOut)
        #expect(machine.lastGood == good)
        #expect(machine.fault?.message(for: .claude, lastGood: nil).contains("Run `claude` and log in") == true)
        #expect(machine.retryPolicy?.onLogActivity == true)
        clock.advance(900)
        machine.recordOutcome(await client(transport, clock).read(), at: clock.now)
        #expect(machine.fault == nil)
    }

    @Test func schemaDriftKeepsTheLastReadingAndRetriesHourly() async {
        let clock = FakeClock(t0)
        let drift = Data(#"{"something_new": {"meter": 3}}"#.utf8)
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: usage)), .success(HTTPResponse(status: 200, body: drift))])
        let c = client(transport, clock)
        var machine = FaultMachine(provider: .claude)
        machine.recordOutcome(await c.read(), at: clock.now)
        let good = machine.lastGood
        clock.advance(300)
        machine.recordOutcome(await c.read(), at: clock.now)
        #expect(machine.fault == .schemaDrift)
        #expect(machine.lastGood == good)
        #expect(machine.retryPolicy?.after == 3600)
    }

    @Test func enterpriseNeverCallsTheAPIAndRetriesDaily() async {
        let clock = FakeClock(t0)
        let transport = FakeTransport([])
        let enterprise = StaticCredentials(credentials: [ClaudeCredentials(accessToken: "tok", expiresAt: clock.now.addingTimeInterval(3600), subscriptionType: "enterprise", rateLimitTier: nil)])
        var machine = FaultMachine(provider: .claude)
        machine.recordOutcome(await client(transport, clock, credentials: enterprise).read(), at: clock.now)
        #expect(machine.fault == .enterprise)
        #expect(transport.recorded.isEmpty)
        #expect(machine.retryPolicy?.after == 86400)
    }

    @Test func cliMissingRetriesOnSettingsChange() {
        var machine = FaultMachine(provider: .codex)
        machine.recordFailure(.cliMissing, at: t0)
        #expect(machine.retryPolicy?.onSettingsChange == true)
        #expect(machine.fault?.message(for: .codex, lastGood: nil).contains("set its path in Settings") == true)
    }

    @Test func outageStreakBacksOffAndStatusPageNamesIt() async {
        let clock = FakeClock(t0)
        let transport = FakeTransport(Array(repeating: .success(HTTPResponse(status: 503, body: Data())), count: 6))
        let c = client(transport, clock)
        var machine = FaultMachine(provider: .claude)
        var delays: [TimeInterval] = []
        for _ in 0..<5 {
            machine.recordOutcome(await c.read(), at: clock.now)
            if let next = machine.nextRetryAt { delays.append(next.timeIntervalSince(clock.now)) }
            clock.advance(60)
        }
        #expect(delays == [60, 120, 300, 600, 900])
        machine.applyStatus(ServiceStatus(level: .partialOutage, description: "Claude Code partial outage (status.claude.com).", checkedAt: clock.now))
        #expect(machine.fault != nil)
    }
}
