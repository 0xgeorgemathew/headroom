import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

/// Replays scripted server lines and records everything the client sends.
final class FakeChannel: JSONLineChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Int: [Data]]  // request id → lines to emit after that request
    private var pending: [Data] = []
    private(set) var sent: [Data] = []
    private(set) var closed = false
    private var waiter: CheckedContinuation<Data?, Never>?
    let silent: Bool

    init(script: [Int: [Data]], silent: Bool = false) {
        self.script = script
        self.silent = silent
    }

    func send(_ line: Data) async throws {
        let toResume: (CheckedContinuation<Data?, Never>, Data)? = lock.withLock {
            sent.append(line)
            guard !silent,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (obj["id"] as? NSNumber)?.intValue,
                  let lines = script[id]
            else { return nil }
            pending.append(contentsOf: lines)
            if let w = waiter, !pending.isEmpty {
                waiter = nil
                return (w, pending.removeFirst())
            }
            return nil
        }
        if let (w, l) = toResume { w.resume(returning: l) }
    }

    func nextLine() async throws -> Data? {
        await withCheckedContinuation { c in
            let immediate: Data?? = lock.withLock {
                if !pending.isEmpty { return .some(pending.removeFirst()) }
                if closed { return .some(nil) }
                waiter = c
                return .none
            }
            if let value = immediate { c.resume(returning: value) }
        }
    }

    func close() async {
        let w: CheckedContinuation<Data?, Never>? = lock.withLock {
            closed = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume(returning: nil)
    }

    var sentMethods: [String] {
        lock.withLock { sent }.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["method"] as? String }
    }

    var sentObjects: [[String: Any]] {
        lock.withLock { sent }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

final class FakeFactory: CodexChannelFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [FakeChannel]
    private(set) var launches: [CodexLaunch] = []
    init(_ channels: [FakeChannel]) { self.channels = channels }

    func open(_ launch: CodexLaunch) async throws -> any JSONLineChannel {
        try lock.withLock {
            launches.append(launch)
            guard !channels.isEmpty else { throw ProcessLaunchError(executable: launch.executable) }
            return channels.removeFirst()
        }
    }

    var recorded: [CodexLaunch] { lock.withLock { launches } }
}

struct FixedProbe: CodexDaemonProbe {
    var listening: Bool
    func isDaemonListening() -> Bool { listening }
}

func line(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

func fixtureLine(_ path: String, id: Int) -> Data {
    var obj = Fixture.json(path)
    obj["id"] = id
    obj.removeValue(forKey: "_comment")
    return line(obj)
}

func happyChannel(account: String = "codex/openai-free-account-read.json", limits: String = "codex/plus-synthetic-ratelimits-read.json") -> FakeChannel {
    FakeChannel(script: [
        1: [line(["method": "configWarning", "params": [:]]), fixtureLine("codex/openai-free-initialize.json", id: 1)],
        2: [line(["method": "account/updated", "params": [:]]), fixtureLine(account, id: 2)],
        3: [fixtureLine(limits, id: 3)],
    ])
}

@Suite struct CodexRateLimitParserTests {
    let now = Date(timeIntervalSince1970: 1_792_400_000)

    func result(_ path: String) -> [String: Any] { Fixture.json(path)["result"] as? [String: Any] ?? [:] }

    @Test func proPlanWindowsCapsAndCredits() throws {
        let r = try CodexRateLimitParser.rateLimits(result("codex/plus-synthetic-ratelimits-read.json"), fetchedAt: now)
        #expect(r.source == .appServer)
        #expect(r.session?.used == 0.12)
        #expect(r.session?.duration == TimeInterval(300 * 60))
        #expect(r.session?.resetsAt == Date(timeIntervalSince1970: 1_792_504_200))
        #expect(r.weekly?.used == 0.41)
        #expect(r.weekly?.duration == TimeInterval(10080 * 60))
        let cap = try #require(r.modelCaps.first)
        #expect(cap.label == "GPT-6 Astra")
        #expect(cap.used == 1)
        #expect(r.resetCredits.count == 3)
        #expect(r.resetCredits.first?.expiresAt == Date(timeIntervalSince1970: 1_792_900_000))
        #expect(r.resetCredits.last?.expiresAt == nil)
        #expect(r.totalResetCredits == 3)
        #expect(r.plan?.pill == "PRO")
        #expect(r.plan?.monthlyPriceUSD == 200)
        #expect(r.accountKey?.hasPrefix("codex-") == true)
        #expect(r.accountKey?.contains("acct-redacted") == false)
        #expect(r.blockedReason == nil)
    }

    @Test func freePlanSingleMonthlyWindow() throws {
        let r = try CodexRateLimitParser.rateLimits(result("codex/openai-free-ratelimits-read.json"), fetchedAt: now)
        #expect(r.session == nil)
        #expect(r.weekly?.duration == TimeInterval(43200 * 60))
        #expect(r.weekly?.used == 0)
        #expect(r.headline?.effectiveDuration == TimeInterval(30 * 86400))
        #expect(r.plan?.pill == "FREE")
        #expect(r.resetCredits.isEmpty)
        #expect(r.totalResetCredits == 0)
    }

    @Test func missingSnapshotIsSchemaDrift() {
        #expect(throws: ProviderFailure(.schemaDrift)) { try CodexRateLimitParser.rateLimits(["foo": 1], fetchedAt: now) }
    }

    @Test func accountStatuses() {
        #expect(CodexRateLimitParser.account(result("codex/signed-out-account-read.json")).fault == .signedOut)
        #expect(CodexRateLimitParser.account(result("codex/apikey-account-read.json")).fault == .apiKeyLogin)
        #expect(CodexRateLimitParser.account(result("codex/enterprise-account-read.json")).fault == .enterprise)
        #expect(CodexRateLimitParser.account(result("codex/openai-free-account-read.json")) == .chatgpt(planType: "free"))
        #expect(CodexRateLimitParser.account(result("codex/openai-free-account-read.json")).fault == nil)
        // A custom provider that needs no OpenAI login is not "signed out".
        #expect(CodexRateLimitParser.account(result("codex/custom-provider-account-read.json")).fault == nil)
    }

    @Test func passiveLogLimits() throws {
        let json = #"{"limit_id":"codex","limit_name":null,"primary":{"used_percent":34.0,"window_minutes":300,"resets_at":1792504200},"secondary":{"used_percent":61.5,"window_minutes":10080,"resets_at":1792846800},"credits":{"has_credits":false,"unlimited":false,"balance":null},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}"#
        let p = try JSONDecoder().decode(CodexPassiveRateLimits.self, from: Data(json.utf8))
        let r = p.reading(at: now)
        #expect(r.source == .passiveLog)
        #expect(r.session?.used == 0.34)
        #expect(r.weekly?.used == 0.615)
        #expect(r.weekly?.duration == 604_800)
        #expect(r.plan?.pill == "PLUS")
        #expect(r.fetchedAt == now)
    }
}

@Suite struct CodexAppServerClientTests {
    let clock = FakeClock(Date(timeIntervalSince1970: 1_792_400_000))

    @Test func spawnsIsolatedServerWithOverrides() async throws {
        let channel = happyChannel()
        let factory = FakeFactory([channel])
        let client = CodexAppServerClient(factory: factory, daemon: FixedProbe(listening: false), clock: clock, locateCodex: { "/bin/codex" })
        let outcome = await client.read()
        #expect(outcome.fault == nil)
        #expect(outcome.reading?.weekly?.used == 0.41)
        let launch = try #require(factory.recorded.first)
        #expect(launch.mode == .spawn)
        #expect(launch.executable == "/bin/codex")
        #expect(launch.arguments.first == "app-server")
        for override in ["features.plugins=false", "features.remote_plugin=false", "features.apps=false", "mcp_servers={}",
                         #"model_provider="openai""#, "features.hooks=false", "features.daemon_auto_start=false"]
        {
            #expect(launch.arguments.contains(override))
        }
        #expect(!launch.arguments.contains("--disable"))
        #expect(channel.sentMethods == ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        #expect(channel.closed)
        #expect(await client.lastLaunchMode == .spawn)
    }

    @Test func reusesRunningDaemonThroughProxy() async throws {
        let factory = FakeFactory([happyChannel()])
        let client = CodexAppServerClient(factory: factory, daemon: FixedProbe(listening: true), clock: clock, locateCodex: { "/bin/codex" })
        let outcome = await client.read()
        #expect(outcome.reading != nil)
        #expect(factory.recorded.map(\.mode) == [.proxy])
        #expect(factory.recorded.first?.arguments == ["app-server", "proxy"])
    }

    @Test func proxyFailureFallsBackToSpawn() async {
        let dead = FakeChannel(script: [:]) // closes without answering
        let factory = FakeFactory([dead, happyChannel()])
        let client = CodexAppServerClient(factory: factory, daemon: FixedProbe(listening: true), clock: clock,
                                          timeout: .milliseconds(200), locateCodex: { "/bin/codex" })
        let outcome = await client.read()
        #expect(outcome.reading != nil)
        #expect(factory.recorded.map(\.mode) == [.proxy, .spawn])
    }

    @Test func signedOutStopsBeforeRateLimits() async {
        let channel = happyChannel(account: "codex/signed-out-account-read.json")
        let client = CodexAppServerClient(factory: FakeFactory([channel]), daemon: FixedProbe(listening: false), clock: clock, locateCodex: { "/bin/codex" })
        let outcome = await client.read()
        #expect(outcome.fault == .signedOut)
        #expect(!channel.sentMethods.contains("account/rateLimits/read"))
        #expect(channel.closed)
    }

    @Test func apiKeyAndEnterprise() async {
        for (fixture, fault) in [("codex/apikey-account-read.json", Fault.apiKeyLogin), ("codex/enterprise-account-read.json", .enterprise)] {
            let client = CodexAppServerClient(factory: FakeFactory([happyChannel(account: fixture)]), daemon: FixedProbe(listening: false),
                                              clock: clock, locateCodex: { "/bin/codex" })
            #expect(await client.read().fault == fault)
        }
    }

    @Test func missingCLI() async {
        let factory = FakeFactory([])
        let client = CodexAppServerClient(factory: factory, daemon: FixedProbe(listening: false), clock: clock, locateCodex: { nil })
        #expect(await client.read().fault == .cliMissing)
        #expect(factory.recorded.isEmpty)
    }

    @Test func timeoutClosesTheServer() async {
        let silent = FakeChannel(script: [:], silent: true)
        let client = CodexAppServerClient(factory: FakeFactory([silent]), daemon: FixedProbe(listening: false), clock: clock,
                                          timeout: .milliseconds(150), locateCodex: { "/bin/codex" })
        let start = Date()
        let outcome = await client.read()
        #expect(outcome.fault?.code == "error")
        #expect(silent.closed)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func rateLimitErrorResponse() async {
        let channel = FakeChannel(script: [
            1: [fixtureLine("codex/openai-free-initialize.json", id: 1)],
            2: [fixtureLine("codex/openai-free-account-read.json", id: 2)],
            3: [line(["id": 3, "error": ["code": -32000, "message": "authentication required"]])],
        ])
        let client = CodexAppServerClient(factory: FakeFactory([channel]), daemon: FixedProbe(listening: false), clock: clock, locateCodex: { "/bin/codex" })
        #expect(await client.read().fault == .signedOut)
    }
}
