import Foundation
import HeadroomKit

/// The complete set of app-server requests Headroom can send (PLAN §5.2, §10). There is no
/// case, and no code path, for redeeming a reset credit, refreshing tokens, logging in or out,
/// or starting a thread or turn.
public enum CodexMethod: String, CaseIterable, Sendable, Hashable {
    case initialize = "initialize"
    case accountRead = "account/read"
    case rateLimitsRead = "account/rateLimits/read"
}

/// The only notification Headroom sends.
public enum CodexNotification: String, CaseIterable, Sendable, Hashable {
    case initialized = "initialized"
}

/// Encodes allowlisted requests. Params are fixed types: `account/read` always says
/// `refreshToken: false`, and the rate-limits params have no `supportsLunaReserve` field.
public enum CodexRequest {
    struct ClientInfo: Encodable {
        let name = "headroom"
        let title = "Headroom"
        let version: String
    }

    struct Capabilities: Encodable {
        let experimentalApi = false
    }

    struct InitializeParams: Encodable {
        let clientInfo: ClientInfo
        let capabilities = Capabilities()
    }

    struct AccountReadParams: Encodable {
        /// `true` would make the server refresh tokens. Headroom never sets it.
        let refreshToken = false
    }

    struct RateLimitsParams: Encodable {
        let excludeResetCreditDetails = false
    }

    struct Envelope<P: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: P
    }

    struct NotificationEnvelope: Encodable {
        let method: String
    }

    public static func encode(_ method: CodexMethod, id: Int, clientVersion: String = "1.0") -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data?
        switch method {
        case .initialize:
            data = try? encoder.encode(Envelope(id: id, method: method.rawValue,
                                                params: InitializeParams(clientInfo: ClientInfo(version: clientVersion))))
        case .accountRead:
            data = try? encoder.encode(Envelope(id: id, method: method.rawValue, params: AccountReadParams()))
        case .rateLimitsRead:
            data = try? encoder.encode(Envelope(id: id, method: method.rawValue, params: RateLimitsParams()))
        }
        return (data ?? Data()) + Data([0x0A])
    }

    public static func encode(_ notification: CodexNotification) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(NotificationEnvelope(method: notification.rawValue))) ?? Data()) + Data([0x0A])
    }
}

/// How the app-server is reached.
public struct CodexLaunch: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable {
        /// Proxy to the user's already-running app-server daemon.
        case proxy
        /// A private, isolated server that exits when the read is done.
        case spawn
    }

    public var mode: Mode
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?

    /// Overrides that keep a spawned server from booting MCP servers, plugins, marketplace sync,
    /// hooks, a daemon or the updater (PLAN §14.2). The `-c features.X=false` form tolerates
    /// feature names a future Codex drops; `--disable <unknown>` would make the server exit.
    /// `model_provider = "openai"` makes the read describe the ChatGPT login in `auth.json`.
    public static let isolationOverrides: [String] = [
        "-c", "features.plugins=false",
        "-c", "features.remote_plugin=false",
        "-c", "features.apps=false",
        "-c", "features.plugin_sharing=false",
        "-c", "features.hooks=false",
        "-c", "features.daemon_auto_start=false",
        "-c", "features.in_app_updates=false",
        "-c", "mcp_servers={}",
        "-c", "analytics.enabled=false",
        "-c", #"model_provider="openai""#,
    ]

    public static func spawn(codex: String, workingDirectory: String?) -> CodexLaunch {
        CodexLaunch(mode: .spawn, executable: codex, arguments: ["app-server"] + isolationOverrides,
                    workingDirectory: workingDirectory)
    }

    public static func proxy(codex: String, workingDirectory: String?) -> CodexLaunch {
        CodexLaunch(mode: .proxy, executable: codex, arguments: ["app-server", "proxy"], workingDirectory: workingDirectory)
    }
}

/// A newline-delimited JSON channel to an app-server.
public protocol JSONLineChannel: Sendable {
    func send(_ line: Data) async throws
    /// The next line, or nil when the server closed its output.
    func nextLine() async throws -> Data?
    /// Ends the server: close stdin, then terminate, then kill. Never leaves it running.
    func close() async
}

public protocol CodexChannelFactory: Sendable {
    func open(_ launch: CodexLaunch) async throws -> any JSONLineChannel
}

/// Says whether the user's app-server daemon is listening.
public protocol CodexDaemonProbe: Sendable {
    func isDaemonListening() -> Bool
}

/// Connects to `~/.codex/app-server-control/app-server-control.sock` and hangs up immediately.
public struct UnixSocketDaemonProbe: CodexDaemonProbe {
    public let socketPath: String

    public init(home: String = NSHomeDirectory()) {
        socketPath = home + "/.codex/app-server-control/app-server-control.sock"
    }

    public func isDaemonListening() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return result == 0
    }
}

/// Spawns the app-server with `Foundation.Process` and speaks newline-delimited JSON over stdio.
public struct ProcessChannelFactory: CodexChannelFactory {
    public init() {}

    public func open(_ launch: CodexLaunch) async throws -> any JSONLineChannel {
        try ProcessLineChannel(launch)
    }
}

final class ProcessLineChannel: JSONLineChannel, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var eof = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false

    init(_ launch: CodexLaunch) throws {
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        if let dir = launch.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["RUST_LOG"] = "error"
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.ingest(data)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw ProcessLaunchError(executable: launch.executable)
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            eof = true
        } else {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { lines.append(Data(line)) }
            }
        }
        var resume: (CheckedContinuation<Data?, Never>, Data?)?
        if let w = waiter {
            if !lines.isEmpty {
                resume = (w, lines.removeFirst())
                waiter = nil
            } else if eof {
                resume = (w, nil)
                waiter = nil
            }
        }
        if eof { output.fileHandleForReading.readabilityHandler = nil }
        lock.unlock()
        if let (w, line) = resume { w.resume(returning: line) }
    }

    func send(_ line: Data) async throws {
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    func nextLine() async throws -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            lock.lock()
            if !lines.isEmpty {
                let l = lines.removeFirst()
                lock.unlock()
                c.resume(returning: l)
            } else if eof || closed {
                lock.unlock()
                c.resume(returning: nil)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func close() async {
        let (already, w) = lock.withLock { () -> (Bool, CheckedContinuation<Data?, Never>?) in
            let state = (closed, waiter)
            closed = true
            waiter = nil
            return state
        }
        w?.resume(returning: nil)
        guard !already else { return }
        try? input.fileHandleForWriting.close()
        let pid = process.processIdentifier
        for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
        for _ in 0..<15 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { kill(pid, SIGKILL) }
        output.fileHandleForReading.readabilityHandler = nil
    }
}
