import Foundation
import HeadroomKit

/// Reads Codex limits through `codex app-server` with only the three allowlisted methods
/// (PLAN §5.2, §14.2). Reuses the user's running daemon through `app-server proxy` when it is
/// listening; otherwise spawns an isolated server and ends it when the read is done.
public actor CodexAppServerClient {
    let factory: any CodexChannelFactory
    let daemon: any CodexDaemonProbe
    let locateCodex: @Sendable () async -> String?
    let clock: any ProviderClock
    let timeout: Duration

    public private(set) var lastLaunchMode: CodexLaunch.Mode?

    public init(
        factory: any CodexChannelFactory = ProcessChannelFactory(),
        daemon: any CodexDaemonProbe = UnixSocketDaemonProbe(),
        clock: any ProviderClock = SystemClock(),
        timeout: Duration = .seconds(10),
        locateCodex: @escaping @Sendable () async -> String?
    ) {
        self.factory = factory
        self.daemon = daemon
        self.clock = clock
        self.timeout = timeout
        self.locateCodex = locateCodex
    }

    public func read() async -> ProviderReadOutcome {
        guard let codex = await locateCodex() else { return .failure(.cliMissing) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if daemon.isDaemonListening() {
            let outcome = await session(.proxy(codex: codex, workingDirectory: dir.path))
            if outcome.reading != nil || !Self.isTransportFailure(outcome.fault) { return outcome }
        }
        return await session(.spawn(codex: codex, workingDirectory: dir.path))
    }

    static func isTransportFailure(_ fault: Fault?) -> Bool {
        if case .failed = fault { return true }
        return false
    }

    private func session(_ launch: CodexLaunch) async -> ProviderReadOutcome {
        lastLaunchMode = launch.mode
        let channel: any JSONLineChannel
        do {
            channel = try await factory.open(launch)
        } catch {
            return .failure(.cliMissing)
        }
        let limit = timeout
        let clock = self.clock
        let result = await withTaskGroup(of: ProviderReadOutcome?.self) { group in
            group.addTask { await Self.exchange(channel, clock: clock) }
            group.addTask {
                do { try await Task.sleep(for: limit) } catch { return nil }
                // Unblocks a pending read so the exchange task finishes and the group can return.
                await channel.close()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await channel.close()
        return result ?? .failure(.failed(reason: "Codex didn't answer within 10 seconds."))
    }

    static func exchange(_ channel: any JSONLineChannel, clock: any ProviderClock) async -> ProviderReadOutcome {
        do {
            try await channel.send(CodexRequest.encode(.initialize, id: 1))
            guard try await response(channel, id: 1) != nil else {
                return .failure(.failed(reason: "Codex app-server didn't start."))
            }
            try await channel.send(CodexRequest.encode(.initialized))
            try await channel.send(CodexRequest.encode(.accountRead, id: 2))
            guard let accountMsg = try await response(channel, id: 2) else {
                return .failure(.failed(reason: "Codex app-server closed early."))
            }
            if let result = accountMsg["result"] as? [String: Any] {
                if let fault = CodexRateLimitParser.account(result).fault { return .failure(fault) }
            } else if accountMsg["error"] != nil {
                return .failure(.signedOut)
            }
            try await channel.send(CodexRequest.encode(.rateLimitsRead, id: 3))
            guard let limitsMsg = try await response(channel, id: 3) else {
                return .failure(.failed(reason: "Codex app-server closed early."))
            }
            if let result = limitsMsg["result"] as? [String: Any] {
                do {
                    return .success(try CodexRateLimitParser.rateLimits(result, fetchedAt: clock.now))
                } catch {
                    return .failure(error.fault)
                }
            }
            let message = ((limitsMsg["error"] as? [String: Any])?["message"] as? String ?? "").lowercased()
            if message.contains("auth") || message.contains("login") || message.contains("401") {
                return .failure(.signedOut)
            }
            return .failure(.failed(reason: "Codex couldn't read rate limits."))
        } catch {
            return .failure(.failed(reason: "Lost the connection to Codex app-server."))
        }
    }

    /// Reads lines until the response with `id`, skipping notifications and server requests.
    static func response(_ channel: any JSONLineChannel, id: Int) async throws -> [String: Any]? {
        while let line = try await channel.nextLine() {
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if msg["method"] != nil { continue }
            if (msg["id"] as? NSNumber)?.intValue == id { return msg }
        }
        return nil
    }
}
