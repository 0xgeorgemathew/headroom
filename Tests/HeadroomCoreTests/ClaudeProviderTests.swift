import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

// MARK: - Test doubles (shared by the provider suites)

enum Fixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func data(_ path: String) -> Data {
        (try? Data(contentsOf: root.appendingPathComponent(path))) ?? Data()
    }

    static func text(_ path: String) -> String { String(decoding: data(path), as: UTF8.self) }

    static func json(_ path: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data(path))) as? [String: Any] ?? [:]
    }
}

final class FakeClock: ProviderClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ t: TimeInterval) { lock.withLock { current = current.addingTimeInterval(t) } }
}

/// Records every spawn; replies from a table keyed by executable.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Hashable { var executable: String; var arguments: [String] }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var replies: [String: ProcessResult]

    init(_ replies: [String: ProcessResult] = [:]) { self.replies = replies }

    func run(_ executable: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { calls.append(Call(executable: executable, arguments: arguments)) }
        guard let reply = lock.withLock({ replies[executable] }) else { throw ProcessLaunchError(executable: executable) }
        return reply
    }

    var recorded: [Call] { lock.withLock { calls } }
}

/// Records every GET; replies from a queue.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Request: Hashable { var url: URL; var headers: [String: String] }
    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, HTTPTransportError>]
    private(set) var requests: [Request] = []

    init(_ queue: [Result<HTTPResponse, HTTPTransportError>]) { self.queue = queue }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        guard HostAllowlist.isAllowed(url) else { throw HTTPTransportError.hostNotAllowed(url.host ?? "") }
        let next: Result<HTTPResponse, HTTPTransportError> = lock.withLock {
            requests.append(Request(url: url, headers: headers))
            return queue.isEmpty ? .failure(.offline) : queue.removeFirst()
        }
        return try next.get()
    }

    var recorded: [Request] { lock.withLock { requests } }
}

struct StaticCredentials: ClaudeCredentialSource {
    var credentials: [ClaudeCredentials]
    let counter = Counter()
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var n = 0
        func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
    }

    func read() async throws(ProviderFailure) -> ClaudeCredentials {
        guard !credentials.isEmpty else { throw ProviderFailure(.signedOut) }
        let i = counter.next()
        return credentials[min(i, credentials.count - 1)]
    }
}

func date(_ iso: String) -> Date { ISODate.parse(iso)! }

func keychainJSON(token: String = "tok-123", expiresMs: Double, sub: String = "max", tier: String = "default_claude_max_20x") -> Data {
    let obj: [String: Any] = [
        "claudeAiOauth": [
            "accessToken": token, "refreshToken": "refresh-secret", "expiresAt": expiresMs,
            "refreshTokenExpiresAt": expiresMs + 1e9, "scopes": ["user:inference"],
            "subscriptionType": sub, "rateLimitTier": tier,
        ],
        "mcpOAuth": ["srv|1": ["accessToken": "mcp-secret", "refreshToken": "mcp-refresh"]],
    ]
    return try! JSONSerialization.data(withJSONObject: obj)
}

// MARK: - Parser

@Suite struct ClaudeUsageParserTests {
    let now = date("2026-10-18T04:00:00Z")

    @Test func teamSeatHasSessionAndScopedCapOnly() throws {
        let r = try ClaudeUsageParser.parse(Fixture.data("claude/usage-team-plain.json"), fetchedAt: now)
        #expect(r.provider == .claude)
        #expect(r.source == .api)
        #expect(r.session?.used == 0.5)
        #expect(r.session?.resetsAt == date("2026-10-18T04:39:59.548985+00:00"))
        #expect(r.weekly == nil)
        #expect(r.modelCaps.count == 1)
        let fable = try #require(r.modelCaps.first)
        #expect(fable.label == "Fable")
        #expect(fable.id == "model:fable")
        #expect(fable.used == 0)
        #expect(fable.isActive == false)
        #expect(r.headline?.id == "model:fable")
        #expect(r.resetCredits.isEmpty)
    }

    @Test func cedarVariantParsesTheSame() throws {
        let r = try ClaudeUsageParser.parse(Fixture.data("claude/usage-team-cedar.json"), fetchedAt: now)
        #expect(r.windows.map(\.id) == ["session", "model:fable"])
        #expect(r.resetCredits.isEmpty)
    }

    @Test func maxSyntheticHasAllWindowsAndGrants() throws {
        let plan = PlanCatalog.claude(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        let r = try ClaudeUsageParser.parse(Fixture.data("claude/usage-max-synthetic.json"), fetchedAt: now, plan: plan, accountKey: "claude-k")
        #expect(r.session?.used == 0.84)
        #expect(r.weekly?.used == 0.18)
        #expect(r.weekly?.resetsAt == date("2026-10-21T00:30:00Z"))
        #expect(r.headline?.kind == .weekly)
        let caps = Dictionary(uniqueKeysWithValues: r.modelCaps.map { ($0.label ?? "", $0.used) })
        #expect(caps["Fable"] == 0.62)
        #expect(caps["Sonnet"] == 0.04) // from the legacy key, absent in limits[]
        #expect(r.resetCredits.count == 2)
        #expect(r.resetCredits.first?.expiresAt == date("2026-10-23T00:00:00Z")) // soonest first
        #expect(r.totalResetCredits == 2)
        #expect(r.plan?.pill == "MAX 20×")
        #expect(r.accountKey == "claude-k")
    }

    @Test func legacyOnlyResponse() throws {
        let r = try ClaudeUsageParser.parse(Fixture.data("claude/usage-legacy-synthetic.json"), fetchedAt: now)
        #expect(r.session?.used == 1.0)
        #expect(r.weekly?.used == 0.715)
        #expect(r.modelCaps.first?.label == "Opus")
        #expect(r.modelCaps.first?.used == 1.0)
    }

    @Test func unknownShapeIsSchemaDrift() {
        #expect(throws: ProviderFailure(.schemaDrift)) {
            try ClaudeUsageParser.parse(Data(#"{"usage": {"weekly": 3}}"#.utf8), fetchedAt: now)
        }
        #expect(throws: ProviderFailure(.schemaDrift)) {
            try ClaudeUsageParser.parse(Data("<html>".utf8), fetchedAt: now)
        }
    }

    @Test func percentAbove100IsClamped() throws {
        let json = #"{"limits":[{"kind":"weekly_all","group":"weekly","percent":130,"resets_at":"2026-10-20T00:00:00Z","scope":null}]}"#
        let r = try ClaudeUsageParser.parse(Data(json.utf8), fetchedAt: now)
        #expect(r.weekly?.used == 1)
    }

    @Test func unknownKindsAreIgnoredNotDrift() throws {
        let json = #"{"limits":[{"kind":"monthly_new","percent":10,"resets_at":null},{"kind":"session","percent":20,"resets_at":"2026-10-18T05:00:00Z"}]}"#
        let r = try ClaudeUsageParser.parse(Data(json.utf8), fetchedAt: now)
        #expect(r.windows.map(\.id) == ["session"])
    }

    @Test func isoDates() {
        #expect(ISODate.parse("2026-10-22T17:00:00+00:00") == ISODate.parse("2026-10-22T22:30:00+05:30"))
        #expect(ISODate.parse("2026-10-18T03:48:18Z")!.timeIntervalSince1970 == 1_792_295_298)
        let micro = ISODate.parse("2026-10-18T04:39:59.548985+00:00")!
        #expect(abs(micro.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) - 0.548985) < 1e-5)
        #expect(ISODate.parse("garbage") == nil)
    }
}

@Suite struct ClaudeUsageTextParserTests {
    @Test func teamText() throws {
        let now = date("2026-10-18T04:00:00Z")
        let r = try #require(ClaudeUsageTextParser.parse(Fixture.text("claude/usage-text-team.txt"), now: now))
        #expect(r.source == .cliText)
        #expect(r.session?.used == 0.51)
        // 10:10am Asia/Calcutta (+05:30) = 04:40 UTC
        #expect(r.session?.resetsAt == date("2026-10-18T04:40:00Z"))
        #expect(r.modelCaps.first?.label == "Fable")
        #expect(r.modelCaps.first?.resetsAt == date("2026-10-22T17:00:00Z"))
    }

    @Test func maxText() throws {
        let now = date("2026-10-20T04:00:00Z")
        let r = try #require(ClaudeUsageTextParser.parse(Fixture.text("claude/usage-max-text-synthetic.txt"), now: now))
        #expect(r.weekly?.used == 0.18)
        #expect(r.weekly?.resetsAt == date("2026-10-21T00:30:00Z"))
        #expect(Set(r.modelCaps.compactMap(\.label)) == ["Sonnet", "Fable"])
        #expect(r.session?.resetsAt == date("2026-10-20T07:00:00Z"))
    }

    @Test func yearRollsOver() throws {
        let now = date("2026-12-30T10:00:00Z")
        let r = try #require(ClaudeUsageTextParser.parse("Current week (all models): 5% used · resets Jan 2 at 9am (UTC)", now: now))
        #expect(r.weekly?.resetsAt == date("2027-01-02T09:00:00Z"))
    }

    @Test func noLimitLinesIsNil() {
        #expect(ClaudeUsageTextParser.parse("Error: not logged in", now: Date()) == nil)
    }
}

// MARK: - Credentials

@Suite struct ClaudeCredentialTests {
    @Test func readsOnlyFourFields() async throws {
        let runner = FakeRunner([SecurityCommand.executable: ProcessResult(status: 0, stdout: keychainJSON(expiresMs: 1_800_000_000_000))])
        let creds = try await ClaudeCredentialReader(runner: runner).read()
        #expect(creds.accessToken == "tok-123")
        #expect(creds.subscriptionType == "max")
        #expect(creds.rateLimitTier == "default_claude_max_20x")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(creds.plan?.pill == "MAX 20×")
        #expect(runner.recorded == [.init(executable: "/usr/bin/security", arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"])])
    }

    @Test func missingItemIsSignedOut() async {
        let runner = FakeRunner([SecurityCommand.executable: ProcessResult(status: 44, stdout: Data())])
        await #expect(throws: ProviderFailure(.signedOut)) { try await ClaudeCredentialReader(runner: runner).read() }
    }

    @Test func refusedAccessIsNotSignedOut() async {
        let runner = FakeRunner([SecurityCommand.executable: ProcessResult(status: 51, stdout: Data())])
        do {
            _ = try await ClaudeCredentialReader(runner: runner).read()
            Issue.record("expected failure")
        } catch {
            #expect(error.fault.code == "error")
        }
    }

    @Test func descriptionNeverShowsToken() {
        let c = ClaudeCredentials(accessToken: "sk-secret-value", expiresAt: nil, subscriptionType: "pro", rateLimitTier: nil)
        #expect(!String(describing: c).contains("sk-secret"))
        #expect(!String(reflecting: c).contains("sk-secret"))
    }

    @Test func accountKeyIsHashed() {
        let json = #"{"oauthAccount":{"organizationUuid":"org-1111","accountUuid":"acc-2222","emailAddress":"a@b.c"}}"#
        let key = ClaudeAccountKey.parse(Data(json.utf8))
        #expect(key?.hasPrefix("claude-") == true)
        #expect(key?.count == "claude-".count + 16)
        #expect(key?.contains("org-1111") == false)
        #expect(ClaudeAccountKey.parse(Data("{}".utf8)) == nil)
    }
}

// MARK: - Client

@Suite struct ClaudeUsageClientTests {
    let now = date("2026-10-20T04:00:00Z")
    var valid: ClaudeCredentials { .init(accessToken: "t1", expiresAt: now.addingTimeInterval(3600), subscriptionType: "max", rateLimitTier: "default_claude_max_20x") }

    func refresher(_ runner: FakeRunner, clock: FakeClock, lastRun: Date? = nil) -> ClaudeRefresher {
        ClaudeRefresher(runner: runner, clock: clock, lastRun: lastRun, locateClaude: { "/opt/bin/claude" })
    }

    @Test func successUsesBearerAndBetaHeader() async throws {
        let clock = FakeClock(now)
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: Fixture.data("claude/usage-max-synthetic.json")))])
        let client = ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [valid]), refresher: nil,
                                       clock: clock, accountKey: { "claude-acct" })
        let outcome = await client.read()
        #expect(outcome.fault == nil)
        #expect(outcome.reading?.weekly?.used == 0.18)
        #expect(outcome.reading?.plan?.pill == "MAX 20×")
        #expect(outcome.reading?.accountKey == "claude-acct")
        let req = try #require(transport.recorded.first)
        #expect(req.url.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        #expect(req.headers["Authorization"] == "Bearer t1")
        #expect(req.headers["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async {
        let clock = FakeClock(now)
        let runner = FakeRunner(["/opt/bin/claude": ProcessResult(status: 0, stdout: Data(Fixture.text("claude/usage-max-text-synthetic.txt").utf8))])
        let fresh = ClaudeCredentials(accessToken: "t2", expiresAt: now.addingTimeInterval(7200), subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        let transport = FakeTransport([
            .success(HTTPResponse(status: 401, body: Data())),
            .success(HTTPResponse(status: 200, body: Fixture.data("claude/usage-max-synthetic.json"))),
        ])
        let client = ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [valid, fresh]),
                                       refresher: refresher(runner, clock: clock), clock: clock, accountKey: { nil })
        let outcome = await client.read()
        #expect(outcome.fault == nil)
        #expect(outcome.reading?.source == .api)
        #expect(transport.recorded.map { $0.headers["Authorization"] } == ["Bearer t1", "Bearer t2"])
        #expect(runner.recorded.count == 1)
        #expect(runner.recorded.first?.arguments == ClaudeUsageCommand.arguments)
    }

    @Test func persistentUnauthorizedIsSignedOutWithTextFallback() async {
        let clock = FakeClock(now)
        let runner = FakeRunner(["/opt/bin/claude": ProcessResult(status: 0, stdout: Data(Fixture.text("claude/usage-max-text-synthetic.txt").utf8))])
        let transport = FakeTransport([.success(HTTPResponse(status: 401, body: Data())), .success(HTTPResponse(status: 401, body: Data()))])
        let client = ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [valid]),
                                       refresher: refresher(runner, clock: clock), clock: clock, accountKey: { nil })
        let outcome = await client.read()
        #expect(outcome.fault == .signedOut)
        #expect(outcome.reading?.source == .cliText)
        #expect(outcome.reading?.weekly?.used == 0.18)
        #expect(transport.recorded.count == 2)
    }

    @Test func expiredTokenRefreshesFirst() async {
        let clock = FakeClock(now)
        let runner = FakeRunner(["/opt/bin/claude": ProcessResult(status: 0, stdout: Data("ok".utf8))])
        let expired = ClaudeCredentials(accessToken: "old", expiresAt: now.addingTimeInterval(-10), subscriptionType: "pro", rateLimitTier: nil)
        let fresh = ClaudeCredentials(accessToken: "new", expiresAt: now.addingTimeInterval(3600), subscriptionType: "pro", rateLimitTier: nil)
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: Fixture.data("claude/usage-legacy-synthetic.json")))])
        let client = ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [expired, fresh]),
                                       refresher: refresher(runner, clock: clock), clock: clock, accountKey: { nil })
        let outcome = await client.read()
        #expect(outcome.reading?.weekly?.used == 0.715)
        #expect(transport.recorded.first?.headers["Authorization"] == "Bearer new")
    }

    @Test func throttledRefreshDoesNotSpawn() async {
        let clock = FakeClock(now)
        let runner = FakeRunner(["/opt/bin/claude": ProcessResult(status: 0, stdout: Data())])
        let transport = FakeTransport([.success(HTTPResponse(status: 401, body: Data()))])
        let client = ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [valid]),
                                       refresher: refresher(runner, clock: clock, lastRun: now.addingTimeInterval(-600)),
                                       clock: clock, accountKey: { nil })
        let outcome = await client.read(popoverOpen: true)
        #expect(outcome.fault == .signedOut)
        #expect(runner.recorded.isEmpty)
    }

    @Test func errorMapping() async {
        func outcome(_ r: Result<HTTPResponse, HTTPTransportError>) async -> Fault? {
            let client = ClaudeUsageClient(transport: FakeTransport([r]), credentials: StaticCredentials(credentials: [valid]),
                                           refresher: nil, clock: FakeClock(now), accountKey: { nil })
            return await client.read().fault
        }
        #expect(await outcome(.failure(.offline)) == .offline)
        #expect(await outcome(.success(HTTPResponse(status: 503, body: Data())))?.code == "outage")
        #expect(await outcome(.success(HTTPResponse(status: 200, body: Data("[]".utf8)))) == .schemaDrift)
        #expect(await outcome(.success(HTTPResponse(status: 429, body: Data())))?.code == "error")
    }

    @Test func noKeychainItemIsSignedOut() async {
        let client = ClaudeUsageClient(transport: FakeTransport([]), credentials: StaticCredentials(credentials: []),
                                       refresher: nil, clock: FakeClock(now), accountKey: { nil })
        #expect(await client.read().fault == .signedOut)
    }

    @Test func enterpriseSkipsTheRead() async {
        let transport = FakeTransport([])
        let ent = ClaudeCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "enterprise", rateLimitTier: nil)
        let client = ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [ent]),
                                       refresher: nil, clock: FakeClock(now), accountKey: { nil })
        #expect(await client.read().fault == .enterprise)
        #expect(transport.recorded.isEmpty)
    }

    @Test func refresherThrottle() async {
        let clock = FakeClock(now)
        let r = ClaudeRefresher(runner: FakeRunner(), clock: clock, lastRun: now.addingTimeInterval(-31 * 60), locateClaude: { nil })
        #expect(await r.canRun(popoverOpen: true))
        #expect(await r.canRun(popoverOpen: false) == false)
        clock.advance(90 * 60)
        #expect(await r.canRun(popoverOpen: false))
        #expect(await r.refreshIfAllowed(popoverOpen: false) == .cliMissing)
    }
}
