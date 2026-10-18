import CryptoKit
import Foundation
import HeadroomKit

/// A read that failed, carrying the exact fault the card should name.
public struct ProviderFailure: Error, Sendable, Hashable {
    public var fault: Fault
    public init(_ fault: Fault) { self.fault = fault }
}

/// What one limit read produced. A read can return a reading and a fault together, e.g. the
/// `claude -p /usage` text fallback after the API kept refusing the token.
public struct ProviderReadOutcome: Sendable, Hashable {
    public var reading: LimitReading?
    public var fault: Fault?

    public init(reading: LimitReading? = nil, fault: Fault? = nil) {
        self.reading = reading
        self.fault = fault
    }

    public static func success(_ reading: LimitReading) -> ProviderReadOutcome { .init(reading: reading) }
    public static func failure(_ fault: Fault, fallback: LimitReading? = nil) -> ProviderReadOutcome {
        .init(reading: fallback, fault: fault)
    }
}

// MARK: - Account keys

/// Hashed account identities. Raw organization, account or ChatGPT IDs are never stored.
public enum AccountKey {
    public static func make(prefix: String, parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: ":").utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return prefix + "-" + hex.prefix(16)
    }
}

// MARK: - Dates

/// Parses the ISO 8601 shapes providers send, including microsecond fractions
/// (`2026-10-18T04:39:59.548985+00:00`) that `ISO8601DateFormatter` rejects.
public enum ISODate {
    public static func parse(_ string: String) -> Date? {
        let b = Array(string.utf8)
        guard b.count >= 19 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= b.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let year = num(0, 4), b[4] == 45, let month = num(5, 2), b[7] == 45, let day = num(8, 2),
              b[10] == 84 || b[10] == 32, let hour = num(11, 2), b[13] == 58, let minute = num(14, 2),
              b[16] == 58, let second = num(17, 2)
        else { return nil }
        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                fraction += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count {
            let c = b[i]
            if c == 90 || c == 122 {
                offset = 0
            } else if c == 43 || c == 45 {
                guard let oh = num(i + 1, 2) else { return nil }
                var om = 0
                if i + 3 < b.count {
                    let mStart = b[i + 3] == 58 ? i + 4 : i + 3
                    om = num(mStart, 2) ?? 0
                }
                offset = (oh * 3600 + om * 60) * (c == 45 ? -1 : 1)
            } else {
                return nil
            }
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard let base = utcCalendar.date(from: comps) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

// MARK: - Processes

public struct ProcessResult: Sendable, Hashable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data = Data(), timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs a short-lived child process. Injected so tests never spawn anything.
public protocol ProcessRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: String?,
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

public struct ProcessLaunchError: Error, Sendable, Hashable {
    public var executable: String
}

/// `Foundation.Process` with both pipes drained concurrently and a hard timeout.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: String?,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let job = RunningJob()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { job.appendOut(d) }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { job.appendErr(d) }
            }
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                job.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                job.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: job.finish(status: p.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProcessLaunchError(executable: executable))
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                job.markTimedOut()
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }
}

/// Collects a child's output under a lock.
private final class RunningJob: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false

    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    func finish(status: Int32) -> ProcessResult {
        lock.lock()
        defer {
            // Drop our copies; the caller owns the only remaining buffer.
            out = Data()
            err = Data()
            lock.unlock()
        }
        return ProcessResult(status: status, stdout: out, stderr: err, timedOut: timedOut)
    }
}

// MARK: - HTTP

/// The only hosts Headroom ever talks to (PLAN §10).
public enum HostAllowlist {
    public static let hosts: Set<String> = ["api.anthropic.com", "status.claude.com", "status.openai.com"]

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum HTTPTransportError: Error, Sendable, Hashable {
    /// The URL is outside `HostAllowlist`; nothing was sent.
    case hostNotAllowed(String)
    case offline
    case timedOut
    case other(String)
}

/// GET-only HTTP. There is deliberately no way to send a body or another method.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse
}

/// `URLSession` transport: ephemeral, no cookies, no cache, no credential storage, and a delegate
/// that refuses redirects or challenges for any host outside the allowlist.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: AllowlistDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        guard HostAllowlist.isAllowed(url) else { throw HTTPTransportError.hostNotAllowed(url.host ?? url.absoluteString) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.other("non-HTTP response") }
            guard HostAllowlist.isAllowed(http.url) else { throw HTTPTransportError.hostNotAllowed(http.url?.host ?? "") }
            return HTTPResponse(status: http.statusCode, body: data)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                throw HTTPTransportError.offline
            case .timedOut:
                throw HTTPTransportError.timedOut
            default:
                throw HTTPTransportError.other("URL error \(error.code.rawValue)")
            }
        }
    }
}

/// Rejects any redirect or authentication challenge that leaves the allowlist.
public final class AllowlistDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    override public init() {}

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        HostAllowlist.isAllowed(request.url) ? request : nil
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard HostAllowlist.hosts.contains(challenge.protectionSpace.host.lowercased()) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.performDefaultHandling, nil)
    }
}

// MARK: - Clock

public protocol ProviderClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: ProviderClock {
    public init() {}
    public var now: Date { Date() }
}
