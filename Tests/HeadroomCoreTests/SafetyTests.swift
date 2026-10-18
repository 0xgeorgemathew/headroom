import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

/// PLAN §10: privacy and safety invariants, enforced by tests rather than promised.
@Suite struct SafetyTests {
    // MARK: Codex allowlist

    @Test func codexMethodSetIsExactlyTheAllowlist() {
        #expect(Set(CodexMethod.allCases.map(\.rawValue)) == ["initialize", "account/read", "account/rateLimits/read"])
        #expect(CodexNotification.allCases.map(\.rawValue) == ["initialized"])
    }

    @Test func encodedRequestsUseOnlyAllowlistedMethods() throws {
        var methods = Set<String>()
        for (i, m) in CodexMethod.allCases.enumerated() {
            let obj = try #require(try JSONSerialization.jsonObject(with: CodexRequest.encode(m, id: i)) as? [String: Any])
            methods.insert(obj["method"] as? String ?? "")
            #expect(obj["jsonrpc"] == nil)
        }
        #expect(methods == ["initialize", "account/read", "account/rateLimits/read"])
    }

    @Test func accountReadNeverAsksForATokenRefresh() throws {
        let obj = try #require(try JSONSerialization.jsonObject(with: CodexRequest.encode(.accountRead, id: 2)) as? [String: Any])
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["refreshToken"] as? Bool == false)
        #expect(params.keys.sorted() == ["refreshToken"])
    }

    @Test func rateLimitsReadNeverOptsIntoLunaReserve() throws {
        let raw = String(decoding: CodexRequest.encode(.rateLimitsRead, id: 3), as: UTF8.self)
        #expect(!raw.contains("supportsLunaReserve"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect((obj["params"] as? [String: Any])?.keys.sorted() == ["excludeResetCreditDetails"])
    }

    @Test func fullExchangeSendsNothingElse() async {
        let channel = happyChannel()
        let client = CodexAppServerClient(factory: FakeFactory([channel]), daemon: FixedProbe(listening: false),
                                          clock: FakeClock(Date()), locateCodex: { "/bin/codex" })
        _ = await client.read()
        let allowed: Set<String> = ["initialize", "initialized", "account/read", "account/rateLimits/read"]
        #expect(Set(channel.sentMethods).isSubset(of: allowed))
        #expect(channel.sentObjects.count == 4)
    }

    @Test func spawnedServerIsIsolated() {
        let launch = CodexLaunch.spawn(codex: "/bin/codex", workingDirectory: "/tmp/x")
        #expect(launch.arguments == ["app-server"] + CodexLaunch.isolationOverrides)
        #expect(CodexLaunch.isolationOverrides == [
            "-c", "features.plugins=false", "-c", "features.remote_plugin=false", "-c", "features.apps=false",
            "-c", "features.plugin_sharing=false", "-c", "features.hooks=false", "-c", "features.daemon_auto_start=false",
            "-c", "features.in_app_updates=false", "-c", "mcp_servers={}", "-c", "analytics.enabled=false",
            "-c", #"model_provider="openai""#,
        ])
        #expect(CodexLaunch.proxy(codex: "/bin/codex", workingDirectory: nil).arguments == ["app-server", "proxy"])
    }

    // MARK: Spawned commands

    @Test func securityIsOnlyEverAReadOfClaudeCodesItem() async throws {
        #expect(SecurityCommand.executable == "/usr/bin/security")
        #expect(SecurityCommand.arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        let runner = FakeRunner([SecurityCommand.executable: ProcessResult(status: 0, stdout: keychainJSON(expiresMs: 1e13))])
        _ = try await ClaudeCredentialReader(runner: runner).read()
        #expect(runner.recorded.map(\.arguments) == [SecurityCommand.arguments])
    }

    @Test func claudeIsOnlyEverSpawnedForUsage() async {
        #expect(ClaudeUsageCommand.arguments == [
            "-p", "/usage", "--no-session-persistence", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
        ])
        let runner = FakeRunner(["/x/claude": ProcessResult(status: 0, stdout: Data())])
        let r = ClaudeRefresher(runner: runner, clock: FakeClock(Date()), locateClaude: { "/x/claude" })
        _ = await r.refreshIfAllowed(popoverOpen: true)
        #expect(runner.recorded == [.init(executable: "/x/claude", arguments: ClaudeUsageCommand.arguments)])
    }

    // MARK: Credentials

    @Test func credentialsHaveNoRefreshTokenField() {
        let c = ClaudeCredentials(accessToken: "a", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        let labels = Mirror(reflecting: c).children.compactMap(\.label)
        #expect(labels.sorted() == ["accessToken", "expiresAt", "rateLimitTier", "subscriptionType"])
        #expect(!labels.contains { $0.lowercased().contains("refresh") })
    }

    @Test func refreshAndMcpTokensAreNotCopied() throws {
        let c = try ClaudeCredentialReader.parse(keychainJSON(expiresMs: 1e13))
        let dump = String(reflecting: c) + Mirror(reflecting: c).children.map { "\($0.value)" }.joined()
        #expect(!dump.contains("refresh-secret"))
        #expect(!dump.contains("mcp-secret"))
    }

    // MARK: Network

    @Test func hostAllowlist() {
        #expect(HostAllowlist.hosts == ["api.anthropic.com", "status.claude.com", "status.openai.com"])
        #expect(HostAllowlist.isAllowed(URL(string: "https://api.anthropic.com/api/oauth/usage")))
        #expect(HostAllowlist.isAllowed(URL(string: "https://status.openai.com/api/v2/summary.json")))
        #expect(!HostAllowlist.isAllowed(URL(string: "http://api.anthropic.com/api/oauth/usage")))
        #expect(!HostAllowlist.isAllowed(URL(string: "https://api.openai.com/v1/responses")))
        #expect(!HostAllowlist.isAllowed(URL(string: "https://api.anthropic.com.evil.example/")))
        #expect(!HostAllowlist.isAllowed(URL(string: "https://chatgpt.com/backend-api/")))
    }

    @Test func realTransportRefusesOtherHostsBeforeSending() async {
        let transport = URLSessionTransport()
        await #expect(throws: HTTPTransportError.hostNotAllowed("example.com")) {
            _ = try await transport.get(URL(string: "https://example.com/")!, headers: [:], timeout: 1)
        }
        await #expect(throws: HTTPTransportError.hostNotAllowed("api.openai.com")) {
            _ = try await transport.get(URL(string: "https://api.openai.com/v1/messages")!, headers: [:], timeout: 1)
        }
    }

    @Test func redirectsOffTheAllowlistAreRefused() async throws {
        let delegate = AllowlistDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://api.anthropic.com/")!)
        let response = try #require(HTTPURLResponse(url: URL(string: "https://api.anthropic.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil))
        let off = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                            newRequest: URLRequest(url: URL(string: "https://tracker.example/x")!))
        #expect(off == nil)
        let on = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                           newRequest: URLRequest(url: URL(string: "https://status.claude.com/x")!))
        #expect(on != nil)
        task.cancel()
        session.invalidateAndCancel()
    }

    @Test func claudeClientOnlyIssuesTheUsageGET() async {
        let transport = FakeTransport([.success(HTTPResponse(status: 200, body: Fixture.data("claude/usage-team-cedar.json")))])
        let creds = ClaudeCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "team", rateLimitTier: nil)
        _ = await ClaudeUsageClient(transport: transport, credentials: StaticCredentials(credentials: [creds]), refresher: nil,
                                    clock: FakeClock(Date()), accountKey: { nil }).read()
        #expect(transport.recorded.map(\.url) == [ClaudeUsageClient.usageURL])
    }

    // MARK: Source scan

    /// Fails if forbidden endpoints, methods or Keychain write APIs ever appear in the sources.
    @Test func sourcesContainNoForbiddenCalls() throws {
        let sources = Fixture.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let forbidden = [
            "rateLimitResetCredit/consume", "chatgptAuthTokens/refresh", "account/login", "account/logout",
            "sendAddCreditsNudgeEmail", "\"thread/", "\"turn/", "supportsLunaReserve\":",
            "SecItemAdd", "SecItemUpdate", "SecItemDelete", "add-generic-password", "delete-generic-password",
            "httpMethod = \"POST\"", "httpMethod = \"PUT\"", "httpMethod = \"DELETE\"", "httpBody",
            "/v1/messages", "/v1/responses", "/v1/chat/completions", "refreshToken: true", "\"refreshToken\": true",
        ]
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(!files.isEmpty)
        for url in files where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for f in forbidden where text.contains(f) { hits.append("\(url.lastPathComponent): \(f)") }
        }
        #expect(hits.isEmpty, "\(hits)")
    }
}
