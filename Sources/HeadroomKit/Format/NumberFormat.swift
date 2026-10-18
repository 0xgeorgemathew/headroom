import Foundation

/// Token, money, multiple and percent strings used across the app, the CLI and shares.
/// Locale-independent on purpose: the same numbers appear in text shares and status lines.
public enum NumberFormat {
    // MARK: Tokens

    /// Three significant digits with K/M/B units, trailing zeros trimmed: `189M`, `5.6M`, `1.09M`, `12.3K`, `940`.
    public static func tokens(_ count: Int64) -> String {
        let negative = count < 0
        let value = Double(count.magnitude)
        let sign = negative ? "-" : ""
        if value < 1000 { return sign + String(Int64(value)) }
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        var index = units.firstIndex { value >= $0.0 } ?? units.count - 1
        var scaled = value / units[index].0
        var text = significant(scaled)
        // Rounding can carry into the next unit (999,600 → "1000K" → "1M").
        if let rounded = Double(text), rounded >= 1000, index > 0 {
            index -= 1
            scaled = value / units[index].0
            text = significant(scaled)
        }
        return sign + text + units[index].1
    }

    /// 3 significant digits for a value in [1, 1000), trailing zeros trimmed.
    private static func significant(_ x: Double) -> String {
        let decimals = x >= 100 ? 0 : x >= 10 ? 1 : 2
        return trimZeros(fixed(x, decimals))
    }

    // MARK: Money

    public enum MoneyStyle: Sendable {
        /// Cents below $10K: `$104.70`, `$1.70`. For span heroes and per-model rows.
        case precise
        /// Whole dollars from $100: `$412`, `$66.10`. For compact rows.
        case compact
    }

    public static func dollars(micros: Int64, style: MoneyStyle = .compact) -> String {
        dollars(Double(micros) / 1_000_000, style: style)
    }

    public static func dollars(_ usd: Double, style: MoneyStyle = .compact) -> String {
        guard usd.isFinite else { return "$—" }
        let sign = usd < 0 ? "-" : ""
        let v = abs(usd)
        if v == 0 { return "$0" }
        if v < 0.005 { return sign + "<$0.01" }
        if v >= 1_000_000 { return sign + "$" + trimZeros(fixed(v / 1_000_000, v >= 10_000_000 ? 1 : 2)) + "M" }
        if v >= 10_000 { return sign + "$" + trimZeros(fixed(v / 1000, v >= 100_000 ? 0 : 1)) + "K" }
        switch style {
        case .compact where v >= 100:
            return sign + "$" + grouped(Int64(v.rounded()))
        default:
            let cents = Int64((v * 100).rounded())
            return sign + "$" + grouped(cents / 100) + "." + pad2(cents % 100)
        }
    }

    // MARK: Multiples

    /// `8.9×`, `4.0×`, `12×`; with a suffix: `8.9× plan`.
    public static func multiple(_ x: Double, suffix: String? = nil) -> String {
        let core: String
        if !x.isFinite {
            core = "∞×"
        } else if x >= 9.95 {
            core = grouped(Int64(x.rounded())) + "×"
        } else {
            core = fixed(x, 1) + "×"
        }
        guard let suffix, !suffix.isEmpty else { return core }
        return core + " " + suffix
    }

    // MARK: Percents

    /// Share of a whole: `96%`, `3.0%`, `0.6%`, `<0.1%`, `0%`. One decimal under 10%.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let p = fraction * 100
        if p <= 0 { return "0%" }
        if p < 0.05 { return "<0.1%" }
        if p < 9.95 { return fixed(p, 1) + "%" }
        return String(Int64(p.rounded())) + "%"
    }

    // MARK: Helpers

    private static func fixed(_ x: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), x)
    }

    private static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    private static func pad2(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }

    private static func grouped(_ n: Int64) -> String {
        let digits = String(n)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}
