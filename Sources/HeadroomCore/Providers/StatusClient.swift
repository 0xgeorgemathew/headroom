import Foundation
import HeadroomKit

/// Service health from the provider's public status page (PLAN §5.4). Optional; no identifiers sent.
public struct ServiceStatus: Codable, Sendable, Hashable {
    public enum Level: Int, Codable, Sendable, Hashable, Comparable {
        case operational = 0
        case degraded = 1
        case partialOutage = 2
        case majorOutage = 3

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    /// "Claude Code partial outage (status.claude.com)". Nil when operational.
    public var description: String?
    public var checkedAt: Date

    public init(level: Level, description: String?, checkedAt: Date) {
        self.level = level
        self.description = description
        self.checkedAt = checkedAt
    }

    public var isOutage: Bool { level >= .partialOutage }

    /// The fault the card shows during an outage.
    public var fault: Fault? { isOutage ? .outage(description: description ?? "Service outage.") : nil }
}

public enum StatusPage {
    public static func url(for provider: Provider) -> URL {
        switch provider {
        case .claude: URL(string: "https://status.claude.com/api/v2/summary.json")!
        case .codex: URL(string: "https://status.openai.com/api/v2/summary.json")!
        }
    }

    static func host(for provider: Provider) -> String { url(for: provider).host ?? "" }

    /// Parses a Statuspage-compatible `summary.json`. Claude: the "Claude Code" component.
    /// Codex: components whose name contains "Codex". Falls back to the page indicator.
    public static func parse(_ data: Data, provider: Provider, checkedAt: Date) -> ServiceStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let components = root["components"] as? [[String: Any]] ?? []
        let matches = components.filter { c in
            let name = (c["name"] as? String ?? "").lowercased()
            switch provider {
            case .claude: return name == "claude code"
            case .codex: return name.contains("codex")
            }
        }
        let level: ServiceStatus.Level
        let subject: String
        if !matches.isEmpty {
            level = matches.map { componentLevel($0["status"] as? String) }.max() ?? .operational
            subject = provider == .claude ? "Claude Code" : "Codex"
        } else {
            let indicator = (root["status"] as? [String: Any])?["indicator"] as? String
            level = indicatorLevel(indicator)
            subject = provider == .claude ? "Claude" : "OpenAI"
        }
        let host = host(for: provider)
        let description: String? = switch level {
        case .operational: nil
        case .degraded: "\(subject) degraded performance (\(host))"
        case .partialOutage: "\(subject) partial outage (\(host))"
        case .majorOutage: "\(subject) major outage (\(host))"
        }
        return ServiceStatus(level: level, description: description, checkedAt: checkedAt)
    }

    static func componentLevel(_ s: String?) -> ServiceStatus.Level {
        switch s {
        case "degraded_performance": .degraded
        case "partial_outage": .partialOutage
        case "major_outage": .majorOutage
        default: .operational
        }
    }

    static func indicatorLevel(_ s: String?) -> ServiceStatus.Level {
        switch s {
        case "minor": .degraded
        case "major": .partialOutage
        case "critical": .majorOutage
        default: .operational
        }
    }
}

public actor StatusClient {
    let transport: any HTTPTransport
    let clock: any ProviderClock

    public init(transport: any HTTPTransport = URLSessionTransport(), clock: any ProviderClock = SystemClock()) {
        self.transport = transport
        self.clock = clock
    }

    /// Nil when the status page couldn't be read; the app then shows no status line.
    public func fetch(_ provider: Provider) async -> ServiceStatus? {
        guard let response = try? await transport.get(StatusPage.url(for: provider), headers: ["Accept": "application/json"], timeout: 10),
              response.status == 200
        else { return nil }
        return StatusPage.parse(response.body, provider: provider, checkedAt: clock.now)
    }
}
