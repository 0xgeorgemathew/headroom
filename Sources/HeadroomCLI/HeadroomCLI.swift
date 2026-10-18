import Foundation
import HeadroomKit
import notify

/// The `headroom` command. Reads `snapshot.json` only: it never touches credentials or the network.
public enum HeadroomCLI {
    public static let version = "0.1.0-beta.2"

    public enum Exit: Int32 {
        case ok = 0
        case usage = 64
        case timeout = 2
        case noData = 3
    }

    public static func run(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           output: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                           snapshotURL: URL = SnapshotFile.url, now: () -> Date = Date.init) -> Int32 {
        var args = args
        let style = Style(environment: environment, isTTY: isatty(STDOUT_FILENO) == 1, forceColor: args.contains("--color"))
        args.removeAll { $0 == "--color" }

        if args.contains("--help") || args.contains("-h") || args.first == "help" {
            output(usage)
            return Exit.ok.rawValue
        }
        if args.contains("--version") {
            output("headroom \(version)")
            return Exit.ok.rawValue
        }
        let json = args.contains("--json")
        switch args.first {
        case "statusline":
            // Status lines are read through pipes (Claude Code, tmux), so only NO_COLOR turns colors off.
            let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
            return statusline(Array(args.dropFirst()), style: Style(colors: !noColor), output: output, url: snapshotURL, now: now())
        case "wait":
            return WaitCommand.run(Array(args.dropFirst()), style: style, output: output, url: snapshotURL, now: now)
        case "mcp":
            return MCPServer.run(url: snapshotURL)
        case nil, "--json", "--refresh":
            if args.contains("--refresh") { Refresh.request(url: snapshotURL, now: now) }
            guard let snapshot = SnapshotFile.read(from: snapshotURL) else {
                output(json ? #"{"error":"no_snapshot","message":"Headroom has not written a snapshot yet. Is the app running?"}"# : "No Headroom data yet. Open Headroom.app (it writes \(snapshotURL.path)).")
                return Exit.noData.rawValue
            }
            if json {
                output(jsonOutput(snapshot, now: now()))
            } else {
                output(Summary.render(snapshot, style: style, now: now()))
            }
            return Exit.ok.rawValue
        default:
            output(usage)
            return Exit.usage.rawValue
        }
    }

    static let usage = """
    usage: headroom [--json] [--refresh]
           headroom statusline [--format claude|tmux|sketchybar|plain] [--provider claude|codex]
           headroom wait [--provider claude|codex|any] [--timeout 6h] [--json]
           headroom mcp

    Shows how much of your weekly Claude and Codex allowance is left against the time
    left until renewal. Reads the snapshot Headroom.app writes; never uses credentials
    or the network. See headroom(1).
    """

    /// The snapshot plus liveness fields, pretty-printed.
    static func jsonOutput(_ s: Snapshot, now: Date) -> String {
        let encoder = SnapshotFile.encoder(pretty: true)
        guard let data = try? encoder.encode(s), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        object["stale"] = !SnapshotFile.writerIsAlive(s)
        object["age_seconds"] = Int(now.timeIntervalSince(s.generatedAt))
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: statusline

    static func statusline(_ args: [String], style: Style, output: (String) -> Void, url: URL, now: Date) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let format = StatusLine.Format(rawValue: value("--format") ?? "claude") ?? .claude
        let only = value("--provider").flatMap(Provider.init(rawValue:))
        guard let s = SnapshotFile.read(from: url) else {
            output("Headroom: no data")
            return Exit.noData.rawValue
        }
        output(StatusLine.render(s, format: format, only: only, colors: style.colors, now: now))
        return Exit.ok.rawValue
    }
}

/// ANSI styling; honors NO_COLOR and plain pipes.
struct Style {
    var colors: Bool

    init(environment: [String: String], isTTY: Bool, forceColor: Bool) {
        if let nc = environment["NO_COLOR"], !nc.isEmpty { colors = false }
        else { colors = forceColor || isTTY }
    }

    init(colors: Bool) { self.colors = colors }

    func paint(_ s: String, _ hex: UInt32?) -> String {
        guard colors, let hex else { return s }
        return "\u{1B}[38;2;\((hex >> 16) & 0xFF);\((hex >> 8) & 0xFF);\(hex & 0xFF)m\(s)\u{1B}[0m"
    }

    func bold(_ s: String) -> String { colors ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    func dim(_ s: String) -> String { colors ? "\u{1B}[2m\(s)\u{1B}[0m" : s }

    static func hex(for state: PacingState) -> UInt32? {
        switch state {
        case .plenty: 0x6AA8FF
        case .onPace: nil
        case .tight: 0xFFC248
        case .veryTight: 0xFF6982
        }
    }

    static func hex(for level: SessionLevel) -> UInt32? {
        switch level {
        case .normal: nil
        case .amber: 0xFFC248
        case .rose, .blocked: 0xFF6982
        }
    }

    static let credit: UInt32 = 0x8CC2FF
    static let muted: UInt32 = 0x8A90A2
}

enum Refresh {
    /// Posts the refresh notification (debounced to ≥ 30 s) and waits up to 10 s for a new snapshot.
    static func request(url: URL, now: () -> Date) {
        let before = SnapshotFile.read(from: url)
        if let b = before, SnapshotFile.writerIsAlive(b), now().timeIntervalSince(b.generatedAt) < 30 { return }
        notify_post(SnapshotFile.refreshNotification)
        guard before.map(SnapshotFile.writerIsAlive) ?? false else { return }
        _ = SnapshotWatch.waitForChange(url: url, after: before?.generatedAt, timeout: 10)
    }
}

/// Blocks (no CPU) until the snapshot's `generated_at` changes, or the timeout passes.
enum SnapshotWatch {
    static func waitForChange(url: URL, after: Date?, timeout: TimeInterval) -> Snapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        let dirFD = open(url.deletingLastPathComponent().path, O_EVTONLY)
        defer { if dirFD >= 0 { close(dirFD) } }
        let kq = kqueue()
        defer { close(kq) }
        if dirFD >= 0 {
            var ev = kevent(ident: UInt(dirFD), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_DELETE), data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }
        while true {
            if let s = SnapshotFile.read(from: url), s.generatedAt != after { return s }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var ts = timespec(tv_sec: Int(left), tv_nsec: Int((left - floor(left)) * 1e9))
            var out = kevent()
            _ = kevent(kq, nil, 0, &out, 1, &ts)
        }
    }
}
