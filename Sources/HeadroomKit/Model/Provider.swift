import Foundation

/// The two allowances Headroom tracks.
public enum Provider: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    public static func < (lhs: Provider, rhs: Provider) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    private var sortIndex: Int {
        switch self {
        case .claude: 0
        case .codex: 1
        }
    }
}
