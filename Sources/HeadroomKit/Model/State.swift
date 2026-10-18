import Foundation

/// Weekly pacing state (PLAN §2.2), ordered by severity so the projection can only raise it.
public enum PacingState: Int, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case plenty = 0
    case onPace = 1
    case tight = 2
    case veryTight = 3

    public static func < (a: PacingState, b: PacingState) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .plenty: "Plenty available"
        case .onPace: "On pace"
        case .tight: "Getting tight"
        case .veryTight: "Very tight"
        }
    }

    /// Short word for the CLI and text shares.
    public var word: String {
        switch self {
        case .plenty: "plenty"
        case .onPace: "on pace"
        case .tight: "tight"
        case .veryTight: "very tight"
        }
    }

    /// Emoji cell used by text shares and the CLI (PLAN §2.4).
    public var emojiCell: String {
        switch self {
        case .plenty: "🟦"
        case .onPace: "⬜"
        case .tight: "🟨"
        case .veryTight: "🟥"
        }
    }

    public static let emptyEmojiCell = "⬛"
}

/// How close the 5-hour session is to its limit (PLAN §2.3).
public enum SessionLevel: Int, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// Under 75% used: a row in the details list.
    case normal = 0
    /// 75–89%: amber banner and a menu-bar timer.
    case amber = 1
    /// 90–99%: the same banner in rose.
    case rose = 2
    /// 100%: blocked until the session resets.
    case blocked = 3

    public static func < (a: SessionLevel, b: SessionLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A reason the latest reading is missing or stale (PLAN §5.5). The card names it exactly.
public enum Fault: Codable, Sendable, Hashable {
    case offline
    case signedOut
    case cliMissing
    case enterprise
    case apiKeyLogin
    case outage(description: String)
    case schemaDrift
    case failed(reason: String)

    /// Faults that keep the last good reading on screen, dimmed.
    public var keepsLastReading: Bool { true }

    /// Card text. `lastGood` is the local time of the last good reading, when there is one.
    public func message(for provider: Provider, lastGood: String?) -> String {
        let showing = lastGood.map { " Showing \($0) reading." } ?? ""
        switch self {
        case .offline:
            return "Offline." + showing
        case .signedOut:
            return provider == .claude
                ? "Signed out of Claude Code. Run `claude` and log in."
                : "Signed out of Codex. Run `codex login` with your ChatGPT account."
        case .cliMissing:
            return "\(provider == .claude ? "Claude Code" : "Codex") CLI not found. Install it, or set its path in Settings."
        case .enterprise:
            return "Enterprise plans don't expose usage limits. Activity and cost still tracked."
        case .apiKeyLogin:
            return "Codex is signed in with an API key, which has no plan limits. Activity and cost still tracked."
        case .outage(let description):
            return description + showing
        case .schemaDrift:
            return "\(provider.displayName) changed its usage format. Headroom needs an update." + showing
        case .failed(let reason):
            return reason + showing
        }
    }

    /// One-word label for the CLI and the snapshot.
    public var code: String {
        switch self {
        case .offline: "offline"
        case .signedOut: "signed_out"
        case .cliMissing: "cli_missing"
        case .enterprise: "enterprise"
        case .apiKeyLogin: "api_key"
        case .outage: "outage"
        case .schemaDrift: "schema_drift"
        case .failed: "error"
        }
    }
}
