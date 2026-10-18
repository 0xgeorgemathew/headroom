import Foundation

/// Model-name normalization so log names match rate-card rows (PLAN §6).
public enum ModelID {
    /// Bare aliases map to the current generation.
    public static let defaultAliases: [String: String] = [
        "opus": "claude-opus-5-5",
        "sonnet": "claude-sonnet-5-5",
        "haiku": "claude-haiku-5-5",
        "fable": "claude-fable-5-1",
    ]

    /// Lowercased and trimmed; used for rate-card keys.
    public static func canonicalKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `claude-haiku-4-5-20251001` → `claude-haiku-4-5`, `claude-opus-5-5[1m]` → `claude-opus-5-5`,
    /// `anthropic/claude-sonnet-5-5` → `claude-sonnet-5-5`, `sonnet` → `claude-sonnet-5-5`.
    public static func normalize(_ raw: String, aliases: [String: String] = defaultAliases) -> String {
        var id = canonicalKey(raw)
        // Bracketed variant suffixes such as `[1m]`.
        if let open = id.firstIndex(of: "["), id.hasSuffix("]") {
            id = String(id[..<open])
        }
        // Routing prefixes (`anthropic/…`, `openai/…`).
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        id = stripDateSuffix(id)
        if let target = aliases[id] { return target }
        return id
    }

    private static func stripDateSuffix(_ id: String) -> String {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        // `-YYYYMMDD`
        if parts.count > 1, let last = parts.last, last.count == 8, isDigits(last), last.hasPrefix("20") {
            return parts.dropLast().joined(separator: "-")
        }
        // `-YYYY-MM-DD`
        if parts.count > 3 {
            let tail = Array(parts.suffix(3))
            if tail.map(\.count) == [4, 2, 2], tail.allSatisfy(isDigits), tail[0].hasPrefix("20") {
                return parts.dropLast(3).joined(separator: "-")
            }
        }
        return id
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
}
