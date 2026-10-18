import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

func statusJSON(components: [(String, String)], indicator: String = "none") -> Data {
    let obj: [String: Any] = [
        "page": ["id": "p", "name": "Status"],
        "components": components.map { ["name": $0.0, "status": $0.1] },
        "status": ["indicator": indicator, "description": "x"],
    ]
    return try! JSONSerialization.data(withJSONObject: obj)
}

@Suite struct StatusTests {
    let now = Date(timeIntervalSince1970: 1_792_400_000)

    @Test func claudeCodeComponent() {
        let data = statusJSON(components: [("claude.ai", "major_outage"), ("Claude Code", "partial_outage")], indicator: "major")
        let s = StatusPage.parse(data, provider: .claude, checkedAt: now)
        #expect(s?.level == .partialOutage)
        #expect(s?.description == "Claude Code partial outage (status.claude.com)")
        #expect(s?.fault == .outage(description: "Claude Code partial outage (status.claude.com)"))
    }

    @Test func operationalHasNoFault() {
        let s = StatusPage.parse(statusJSON(components: [("Claude Code", "operational")]), provider: .claude, checkedAt: now)
        #expect(s?.level == .operational)
        #expect(s?.fault == nil)
        #expect(s?.description == nil)
    }

    @Test func codexComponentsByName() {
        let data = statusJSON(components: [("Responses", "major_outage"), ("Codex in ChatGPT Desktop", "degraded_performance")])
        let s = StatusPage.parse(data, provider: .codex, checkedAt: now)
        #expect(s?.level == .degraded)
        #expect(s?.isOutage == false)
    }

    @Test func fallsBackToPageIndicator() {
        let s = StatusPage.parse(statusJSON(components: [("Chat", "operational")], indicator: "critical"), provider: .codex, checkedAt: now)
        #expect(s?.level == .majorOutage)
        #expect(s?.description == "OpenAI major outage (status.openai.com)")
    }

    @Test func clientFetchesTheRightPage() async {
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: statusJSON(components: [("Claude Code", "operational")])))])
        let s = await StatusClient(transport: transport, clock: FakeClock(now)).fetch(.claude)
        #expect(s?.level == .operational)
        #expect(transport.recorded.first?.url.absoluteString == "https://status.claude.com/api/v2/summary.json")
        #expect(transport.recorded.first?.headers.keys.sorted() == ["Accept"])
        #expect(StatusPage.url(for: .codex).absoluteString == "https://status.openai.com/api/v2/summary.json")
    }

    @Test func unreadablePageIsNil() async {
        let s = await StatusClient(transport: FakeTransport([.failure(.offline)]), clock: FakeClock(now)).fetch(.codex)
        #expect(s == nil)
    }
}

@Suite struct FaultMachineTests {
    let t0 = Date(timeIntervalSince1970: 1_792_400_000)

    func reading(_ at: Date) -> LimitReading {
        LimitReading(provider: .claude, fetchedAt: at, source: .api, windows: [LimitWindow(id: "weekly", kind: .weekly, used: 0.3, resetsAt: at)])
    }

    @Test func keepsLastGoodReadingAcrossFaults() {
        var m = FaultMachine(provider: .claude)
        m.recordSuccess(reading(t0))
        m.recordFailure(.offline, at: t0.addingTimeInterval(600))
        #expect(m.fault == .offline)
        #expect(m.lastGood?.fetchedAt == t0)
        #expect(m.lastGoodAge(at: t0.addingTimeInterval(900)) == 900)
        m.recordSuccess(reading(t0.addingTimeInterval(1000)))
        #expect(m.fault == nil)
    }

    @Test func outageBackoffSteps() {
        var m = FaultMachine(provider: .codex)
        var delays: [TimeInterval] = []
        for i in 0..<7 {
            m.recordFailure(.outage(description: "x"), at: t0.addingTimeInterval(Double(i)))
            delays.append(m.retryPolicy?.after ?? -1)
        }
        #expect(delays == [60, 120, 300, 600, 900, 900, 900])
        #expect(m.nextRetryAt == t0.addingTimeInterval(6 + 900))
        m.recordFailure(.signedOut, at: t0)
        #expect(m.failureStreak == 1)
    }

    @Test func policiesPerFault() {
        #expect(FaultMachine.policy(for: .offline, streak: 1).onPathSatisfied)
        #expect(FaultMachine.policy(for: .signedOut, streak: 1) == RetryPolicy(after: 900, onLogActivity: true))
        #expect(FaultMachine.policy(for: .cliMissing, streak: 1) == RetryPolicy(after: 3600, onSettingsChange: true))
        #expect(FaultMachine.policy(for: .enterprise, streak: 1).after == 86400)
        #expect(FaultMachine.policy(for: .schemaDrift, streak: 1).after == 3600)
    }

    @Test func fallbackReadingReplacesOnlyWhenNewer() {
        var m = FaultMachine(provider: .claude)
        m.recordSuccess(reading(t0))
        var text = reading(t0.addingTimeInterval(60))
        text.source = .cliText
        m.recordOutcome(.failure(.signedOut, fallback: text), at: t0.addingTimeInterval(60))
        #expect(m.lastGood?.source == .cliText)
        m.recordOutcome(.failure(.signedOut, fallback: reading(t0.addingTimeInterval(-60))), at: t0.addingTimeInterval(120))
        #expect(m.lastGood?.source == .cliText)
    }

    @Test func statusOutageShowsWhenReadsAreHealthy() {
        var m = FaultMachine(provider: .claude)
        m.recordSuccess(reading(t0))
        m.applyStatus(ServiceStatus(level: .majorOutage, description: "Claude Code major outage (status.claude.com)", checkedAt: t0))
        #expect(m.fault?.code == "outage")
        #expect(m.retryPolicy == nil)
        m.recordFailure(.offline, at: t0)
        #expect(m.fault == .offline) // the read fault names the exact problem first
        m.applyStatus(ServiceStatus(level: .operational, description: nil, checkedAt: t0))
        m.recordSuccess(reading(t0))
        #expect(m.fault == nil)
    }
}

@Suite struct CLILocatorTests {
    @Test func loginShellFirst() async {
        let runner = FakeRunner(["/bin/zsh": ProcessResult(status: 0, stdout: Data("/Users/u/.bun/bin/claude\n".utf8))])
        let loc = CLILocator(runner: runner, home: "/Users/u", isExecutable: { $0 == "/Users/u/.bun/bin/claude" })
        #expect(await loc.locate(.claude) == "/Users/u/.bun/bin/claude")
        #expect(runner.recorded.first?.arguments == ["-lc", "command -v claude"])
    }

    @Test func knownDirsFallback() async {
        let runner = FakeRunner(["/bin/zsh": ProcessResult(status: 1, stdout: Data())])
        let loc = CLILocator(runner: runner, home: "/Users/u", isExecutable: { $0 == "/opt/homebrew/bin/codex" })
        #expect(await loc.locate(.codex) == "/opt/homebrew/bin/codex")
    }

    @Test func overrideWinsAndIsValidated() async {
        let runner = FakeRunner()
        let loc = CLILocator(runner: runner, home: "/Users/u", isExecutable: { $0 == "/Users/u/tools/codex" })
        #expect(await loc.locate(.codex, override: "~/tools/codex") == "/Users/u/tools/codex")
        #expect(await loc.locate(.codex, override: "/nope/codex") == nil)
        #expect(runner.recorded.isEmpty)
    }

    @Test func missingEverywhere() async {
        let loc = CLILocator(runner: FakeRunner(), home: "/Users/u", isExecutable: { _ in false })
        #expect(await loc.locate(.claude) == nil)
    }

    @Test func resolverCachesForAnHour() async {
        let runner = FakeRunner(["/bin/zsh": ProcessResult(status: 0, stdout: Data("/x/claude\n".utf8))])
        let clock = FakeClock(Date(timeIntervalSince1970: 0))
        let resolver = CLIResolver(locator: CLILocator(runner: runner, home: "/h", isExecutable: { _ in true }), clock: clock)
        _ = await resolver.path(for: .claude)
        _ = await resolver.path(for: .claude)
        #expect(runner.recorded.count == 1)
        clock.advance(3601)
        _ = await resolver.path(for: .claude)
        #expect(runner.recorded.count == 2)
        await resolver.setOverride("/y/claude", for: .claude)
        #expect(await resolver.path(for: .claude) == "/y/claude")
    }
}
