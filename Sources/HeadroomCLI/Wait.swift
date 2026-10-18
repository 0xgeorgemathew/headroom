import Foundation
import HeadroomKit

/// `headroom wait`: blocks while the 5-hour session or weekly limit is at 100%, or a major
/// outage is active. Wakes on snapshot changes (kqueue) or at the reset time. Zero CPU while waiting.
enum WaitCommand {
    static func run(_ args: [String], style: Style, output: (String) -> Void, url: URL, now: () -> Date) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let which = value("--provider") ?? "any"
        let json = args.contains("--json")
        guard let timeout = parseDuration(value("--timeout") ?? "6h") else {
            output("headroom wait: bad --timeout (use e.g. 90s, 45m, 6h, 2d)")
            return HeadroomCLI.Exit.usage.rawValue
        }
        let wanted: [Provider]? = which == "any" ? nil : Provider(rawValue: which).map { [$0] }
        if which != "any" && wanted == nil {
            output("headroom wait: --provider must be claude, codex or any")
            return HeadroomCLI.Exit.usage.rawValue
        }
        let deadline = now().addingTimeInterval(timeout)
        var announced = false
        while true {
            guard let s = SnapshotFile.read(from: url) else {
                output(json ? #"{"blocked_by":null,"until":null,"error":"no_snapshot"}"# : "No Headroom data yet. Open Headroom.app.")
                return HeadroomCLI.Exit.noData.rawValue
            }
            let candidates = s.providers.filter { wanted?.contains($0.id) ?? true }
            // `any`: capacity is back as soon as one provider is unblocked.
            let blocked = candidates.filter { $0.blocked != nil }
            let stillBlocked = wanted == nil ? (blocked.count == candidates.count && !blocked.isEmpty) : !blocked.isEmpty
            if !stillBlocked {
                if json && !announced { output(#"{"blocked_by":null,"until":null}"#) }
                if announced && !json { output("▶ capacity is back") }
                return HeadroomCLI.Exit.ok.rawValue
            }
            let soonest = blocked.min { ($0.blocked?.until ?? .distantFuture) < ($1.blocked?.until ?? .distantFuture) }!
            if !announced {
                announced = true
                let b = soonest.blocked!
                if json {
                    let until = b.until.map { "\"\(ISO8601DateFormatter.headroom.string(from: $0))\"" } ?? "null"
                    output("{\"provider\":\"\(soonest.id.rawValue)\",\"blocked_by\":\"\(b.by)\",\"until\":\(until)}")
                } else {
                    output(style.dim("⏸ waiting on " + description(b, provider: soonest.id, now: now())))
                }
            }
            let left = deadline.timeIntervalSince(now())
            if left <= 0 { return HeadroomCLI.Exit.timeout.rawValue }
            // Sleep until the snapshot changes, the reset time passes, or the timeout.
            let untilReset = (soonest.blocked?.until).map { $0.timeIntervalSince(now()) + 2 } ?? left
            _ = SnapshotWatch.waitForChange(url: url, after: s.generatedAt, timeout: max(1, min(left, untilReset)))
        }
    }

    static func description(_ b: BlockedSnapshot, provider: Provider, now: Date) -> String {
        let what: String = switch b.by {
        case "session": "the 5-hour session"
        case "weekly": "the weekly limit"
        case "model_cap": "the \(b.detail ?? "model") cap"
        default: "an outage"
        }
        guard let until = b.until else { return "\(provider.displayName): \(what)" }
        return "\(what) · \(TimeFormat.shortClock(until, calendar: .current, locale: .current)) (\(TimeFormat.compact(until.timeIntervalSince(now))))"
    }

    /// "90s", "45m", "6h", "2d", or plain seconds.
    static func parseDuration(_ s: String) -> TimeInterval? {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let last = s.last, let mult = units[last], let v = Double(s.dropLast()) { return v * mult }
        return Double(s)
    }
}
