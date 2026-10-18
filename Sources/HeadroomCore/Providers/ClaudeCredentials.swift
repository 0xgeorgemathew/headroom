import Foundation
import HeadroomKit

/// The four fields Headroom copies out of Claude Code's Keychain item. The refresh token is not
/// one of them: there is no field for it, so it can never be stored (PLAN §10).
public struct ClaudeCredentials: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }

    public var plan: PlanInfo? { PlanCatalog.claude(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier) }

    /// Never prints the token.
    public var description: String {
        "ClaudeCredentials(token: <redacted>, subscriptionType: \(subscriptionType ?? "nil"), rateLimitTier: \(rateLimitTier ?? "nil"))"
    }

    public var debugDescription: String { description }
}

/// The exact, only `security` invocation Headroom makes: a read of Claude Code's item through
/// Apple's tool, which is already on the item's access list, so there is no Keychain prompt.
public enum SecurityCommand {
    public static let executable = "/usr/bin/security"
    public static let service = "Claude Code-credentials"
    public static let arguments: [String] = ["find-generic-password", "-s", service, "-w"]
    /// `security` exits 44 when the item does not exist.
    public static let itemNotFoundStatus: Int32 = 44
}

public protocol ClaudeCredentialSource: Sendable {
    func read() async throws(ProviderFailure) -> ClaudeCredentials
}

/// Reads Claude Code's Keychain item via `/usr/bin/security`, parses it in memory, copies four
/// fields and zeroes the raw buffer. The item also holds MCP OAuth tokens; none are kept.
public struct ClaudeCredentialReader: ClaudeCredentialSource {
    let runner: any ProcessRunning

    public init(runner: any ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    public func read() async throws(ProviderFailure) -> ClaudeCredentials {
        let result: ProcessResult
        do {
            result = try await runner.run(SecurityCommand.executable, arguments: SecurityCommand.arguments,
                                          currentDirectory: nil, timeout: 10)
        } catch {
            throw ProviderFailure(.failed(reason: "Couldn't read Claude Code's Keychain item."))
        }
        var raw = result.stdout
        defer { raw.resetBytes(in: 0..<raw.count) }
        if result.status == SecurityCommand.itemNotFoundStatus || (result.status == 0 && raw.isEmpty) {
            throw ProviderFailure(.signedOut)
        }
        guard result.status == 0 else {
            throw ProviderFailure(.failed(reason: "Keychain access to Claude Code's credentials was refused."))
        }
        return try Self.parse(raw)
    }

    /// Copies `accessToken`, `expiresAt`, `subscriptionType` and `rateLimitTier`; nothing else.
    static func parse(_ raw: Data) throws(ProviderFailure) -> ClaudeCredentials {
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw ProviderFailure(.signedOut) }
        let expires: Date? = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

/// Account identity for keying state: a hash of `~/.claude.json` organization + account UUIDs.
public enum ClaudeAccountKey {
    public static func read(configPath: String = NSHomeDirectory() + "/.claude.json") -> String? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let org = account["organizationUuid"] as? String ?? ""
        let user = account["accountUuid"] as? String ?? ""
        guard !(org.isEmpty && user.isEmpty) else { return nil }
        return AccountKey.make(prefix: "claude", parts: [org, user])
    }
}

/// The exact, only `claude` invocation Headroom makes (PLAN §5.1). `/usage` is a local command:
/// it sends no prompt, uses no tokens and leaves no session behind (verified in Phase 0). Claude
/// Code refreshes its own credentials when it starts; Headroom never does.
public enum ClaudeUsageCommand {
    public static let arguments: [String] = [
        "-p", "/usage",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--settings", #"{"disableAllHooks":true}"#,
    ]
}

/// Runs `claude -p /usage …` at most every 30 minutes while the popover is open and every
/// 2 hours otherwise, because it starts Claude Code itself (~500 MB for a few seconds).
public actor ClaudeRefresher {
    public static let openInterval: TimeInterval = 30 * 60
    public static let closedInterval: TimeInterval = 2 * 3600

    let runner: any ProcessRunning
    let locateClaude: @Sendable () async -> String?
    let clock: any ProviderClock
    private(set) var lastRun: Date?

    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        clock: any ProviderClock = SystemClock(),
        lastRun: Date? = nil,
        locateClaude: @escaping @Sendable () async -> String?
    ) {
        self.runner = runner
        self.clock = clock
        self.lastRun = lastRun
        self.locateClaude = locateClaude
    }

    public enum Outcome: Sendable, Hashable {
        case ran(output: String)
        case throttled
        case cliMissing
        case failed
    }

    public func canRun(popoverOpen: Bool) -> Bool {
        guard let lastRun else { return true }
        let interval = popoverOpen ? Self.openInterval : Self.closedInterval
        return clock.now.timeIntervalSince(lastRun) >= interval
    }

    public func refreshIfAllowed(popoverOpen: Bool) async -> Outcome {
        guard canRun(popoverOpen: popoverOpen) else { return .throttled }
        guard let claude = await locateClaude() else { return .cliMissing }
        lastRun = clock.now
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let result = try? await runner.run(claude, arguments: ClaudeUsageCommand.arguments,
                                                 currentDirectory: dir.path, timeout: 60),
              result.status == 0, !result.timedOut
        else { return .failed }
        return .ran(output: String(decoding: result.stdout, as: UTF8.self))
    }
}
