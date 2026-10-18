import Foundation
import HeadroomKit
import Network

/// When to try again after a fault (PLAN §5.5).
public struct RetryPolicy: Sendable, Hashable {
    /// Retry after this delay. Nil means "only on an event".
    public var after: TimeInterval?
    public var onPathSatisfied: Bool
    public var onLogActivity: Bool
    public var onSettingsChange: Bool

    public init(after: TimeInterval?, onPathSatisfied: Bool = false, onLogActivity: Bool = false, onSettingsChange: Bool = false) {
        self.after = after
        self.onPathSatisfied = onPathSatisfied
        self.onLogActivity = onLogActivity
        self.onSettingsChange = onSettingsChange
    }
}

/// Per-provider fault state: the current fault, the last good reading, and the retry schedule.
/// A fault never erases the last good reading; the card keeps it and labels its age.
public struct FaultMachine: Sendable, Hashable {
    /// Backoff for outages and transient errors: 1 → 2 → 5 → 10 → 15 minutes.
    public static let backoff: [TimeInterval] = [60, 120, 300, 600, 900]

    public let provider: Provider
    public private(set) var readFault: Fault?
    public private(set) var statusFault: Fault?
    public private(set) var lastGood: LimitReading?
    public private(set) var lastFailureAt: Date?
    public private(set) var failureStreak = 0

    public init(provider: Provider, lastGood: LimitReading? = nil) {
        self.provider = provider
        self.lastGood = lastGood
    }

    /// What the card shows: a read fault first, then a status-page outage.
    public var fault: Fault? { readFault ?? statusFault }

    public mutating func recordSuccess(_ reading: LimitReading) {
        lastGood = reading
        readFault = nil
        failureStreak = 0
        lastFailureAt = nil
    }

    /// Records a failed read. `fallback` (e.g. the `/usage` text) replaces the last good reading
    /// only when it is newer.
    public mutating func recordFailure(_ fault: Fault, at now: Date, fallback: LimitReading? = nil) {
        if let fallback, fallback.fetchedAt >= (lastGood?.fetchedAt ?? .distantPast) { lastGood = fallback }
        if Self.isTransient(fault), readFault.map(Self.isTransient) ?? true {
            failureStreak += 1
        } else {
            failureStreak = 1
        }
        readFault = fault
        lastFailureAt = now
    }

    public mutating func recordOutcome(_ outcome: ProviderReadOutcome, at now: Date) {
        if let fault = outcome.fault {
            recordFailure(fault, at: now, fallback: outcome.reading)
        } else if let reading = outcome.reading {
            recordSuccess(reading)
        }
    }

    public mutating func applyStatus(_ status: ServiceStatus?) {
        statusFault = status?.fault
    }

    public func lastGoodAge(at now: Date) -> TimeInterval? {
        lastGood.map { now.timeIntervalSince($0.fetchedAt) }
    }

    static func isTransient(_ fault: Fault) -> Bool {
        switch fault {
        case .outage, .failed: true
        default: false
        }
    }

    public static func policy(for fault: Fault, streak: Int) -> RetryPolicy {
        switch fault {
        case .offline:
            RetryPolicy(after: 15 * 60, onPathSatisfied: true)
        case .signedOut:
            RetryPolicy(after: 15 * 60, onLogActivity: true)
        case .cliMissing:
            RetryPolicy(after: 3600, onSettingsChange: true)
        case .enterprise, .apiKeyLogin:
            RetryPolicy(after: 86400, onSettingsChange: true)
        case .schemaDrift:
            RetryPolicy(after: 3600)
        case .outage, .failed:
            RetryPolicy(after: backoff[min(max(streak, 1), backoff.count) - 1], onPathSatisfied: true)
        }
    }

    /// The retry policy for the current read fault, or nil when healthy.
    public var retryPolicy: RetryPolicy? {
        readFault.map { Self.policy(for: $0, streak: failureStreak) }
    }

    /// When the next timed retry is due.
    public var nextRetryAt: Date? {
        guard let lastFailureAt, let after = retryPolicy?.after else { return nil }
        return lastFailureAt.addingTimeInterval(after)
    }
}

/// Network reachability behind a protocol so tests can flip it.
public protocol NetworkReachability: AnyObject, Sendable {
    var isSatisfied: Bool { get }
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

public final class NWPathReachability: NetworkReachability, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "headroom.path", qos: .utility)
    private let lock = NSLock()
    private var satisfied = true

    public init() {}

    public var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let ok = path.status == .satisfied
            self.lock.lock()
            let changed = ok != self.satisfied
            self.satisfied = ok
            self.lock.unlock()
            if changed { onChange(ok) }
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}
