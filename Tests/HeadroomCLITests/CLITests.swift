import Foundation
import Testing
@testable import HeadroomCLI
import HeadroomKit

@Suite(.serialized) struct CLITests {
    let now = Date(timeIntervalSince1970: 1_792_500_000)

    func snapshot(blocked: Bool = false, sessionUsed: Double = 0.84, pid: Int32 = getpid()) -> Snapshot {
        let claude = ProviderSnapshot(
            id: .claude, plan: "MAX 20×", readingAt: now.addingTimeInterval(-120), source: "api",
            weekly: WeeklySnapshot(label: nil, used: 0.18, left: 0.82, resetsAt: now.addingTimeInterval(20 * 3600), windowHours: 168,
                                   state: "plenty", multiple: 6.9, cells: 4, hourglass: true, runsOutAt: nil, unusedAtReset: 0.80,
                                   verdict: VerdictSnapshot(title: "Plenty available", primary: "Spend it before it renews tomorrow at 6 AM.", secondary: "At today's pace, 80% renews unused.")),
            session: SessionSnapshot(used: sessionUsed, left: 1 - sessionUsed, resetsAt: now.addingTimeInterval(48 * 60), level: sessionUsed >= 1 ? "blocked" : "amber"),
            blocked: blocked ? BlockedSnapshot(by: "session", detail: nil, until: now.addingTimeInterval(48 * 60)) : nil,
            weekCostUSD: 412, planMultiple: 8.9)
        let codex = ProviderSnapshot(
            id: .codex, plan: "PRO", readingAt: now.addingTimeInterval(-60), source: "appServer",
            weekly: WeeklySnapshot(label: nil, used: 0.41, left: 0.59, resetsAt: now.addingTimeInterval(4 * 86400), windowHours: 168,
                                   state: "tight", multiple: 1.0, cells: 3, hourglass: false, runsOutAt: now.addingTimeInterval(3 * 86400 + 3 * 3600),
                                   unusedAtReset: nil, verdict: VerdictSnapshot(title: "Getting tight", primary: "Runs out Friday 4 PM at today's pace.", secondary: "")),
            credits: CreditsSnapshot(available: 3, nextExpiry: now.addingTimeInterval(3 * 86400), expiringSoon: 1))
        return Snapshot(generatedAt: now, appVersion: "test", appPID: pid, providers: [claude, codex])
    }

    func write(_ s: Snapshot) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("snapshot.json")
        try SnapshotFile.encoder().encode(s).write(to: url)
        return url
    }

    func run(_ args: [String], url: URL, env: [String: String] = ["NO_COLOR": "1"]) -> (Int32, String) {
        var lines: [String] = []
        let code = HeadroomCLI.run(args, environment: env, output: { lines.append($0) }, snapshotURL: url, now: { now })
        return (code, lines.joined(separator: "\n"))
    }

    @Test func sessionForecastLines() {
        let style = Style(colors: false)
        let cal = Calendar(identifier: .gregorian)
        let loc = Locale(identifier: "en_US")
        let runsOut = SessionSnapshot(used: 0.5, left: 0.5, resetsAt: now.addingTimeInterval(3 * 3600), level: "normal",
                                      outlook: "runs_out", runsOutAt: now.addingTimeInterval(3600), leftAtReset: 0)
        #expect(Summary.sessionLine(runsOut, style: style, now: now, calendar: cal, locale: loc)?.contains("5-hour session 50% left · runs out ~") == true)
        #expect(Summary.sessionLine(runsOut, style: style, now: now, calendar: cal, locale: loc)?.hasSuffix("2h early") == true)
        let calm = SessionSnapshot(used: 0.2, left: 0.8, resetsAt: now.addingTimeInterval(3600), level: "normal", outlook: "comfortable", leftAtReset: 0.6)
        #expect(Summary.sessionLine(calm, style: style, now: now, calendar: cal, locale: loc)?.hasSuffix("~60% spare at this pace") == true)
        let idle = SessionSnapshot(used: 0, left: 1, resetsAt: nil, level: "normal", outlook: "idle")
        #expect(Summary.sessionLine(idle, style: style, now: now, calendar: cal, locale: loc) == nil)
        // Snapshots from older apps carry no outlook: only the warning, as before.
        let old = SessionSnapshot(used: 0.2, left: 0.8, resetsAt: now.addingTimeInterval(3600), level: "normal")
        #expect(Summary.sessionLine(old, style: style, now: now, calendar: cal, locale: loc) == nil)
    }

    @Test func summaryMatchesTheMockupLayout() throws {
        let url = try write(snapshot())
        let (code, out) = run([], url: url)
        #expect(code == 0)
        #expect(out.contains("Claude  🟦🟦🟦🟦⬛   82% · renews in 20h ⏳"))
        #expect(out.contains("↳ plenty · 80% renews unused at this pace"))
        #expect(out.contains("↳ ⚠ 5-hour session 16% left · resets"))
        #expect(out.contains("Codex   🟨🟨🟨⬛⬛   59% · renews in 4d"))
        #expect(out.contains("↳ tight · runs out"))
        #expect(out.contains("21h early"))
        #expect(out.contains("↳ ⏳ 1 reset credit lapses in 3d"))
        #expect(!out.contains("\u{1B}["))
    }

    @Test func colorsOnlyWhenAllowed() throws {
        let url = try write(snapshot())
        let (_, colored) = run(["--color"], url: url, env: [:])
        #expect(colored.contains("\u{1B}[38;2;"))
        let (_, plain) = run(["--color"], url: url, env: ["NO_COLOR": "1"])
        #expect(!plain.contains("\u{1B}["))
    }

    @Test func jsonCarriesLivenessAndSchema() throws {
        let url = try write(snapshot(pid: 999_999))
        let (code, out) = run(["--json"], url: url)
        #expect(code == 0)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["schema"] as? Int == 1)
        #expect(obj["stale"] as? Bool == true)
        #expect(obj["age_seconds"] as? Int == 0)
        #expect((obj["providers"] as? [[String: Any]])?.count == 2)
    }

    @Test func statuslineFormats() throws {
        let url = try write(snapshot())
        let (_, plain) = run(["statusline", "--format", "plain"], url: url)
        #expect(plain == "Claude 🟦🟦🟦🟦⬛ 82% ⏱48m  Codex 🟨🟨🟨⬛⬛ 59%")
        let (_, tmux) = run(["statusline", "--format", "tmux"], url: url, env: [:])
        #expect(tmux.contains("#[fg=#FFC248]⏱48m#[default]"))
        let (_, claudeFmt) = run(["statusline", "--color"], url: url, env: [:])
        #expect(claudeFmt.contains("\u{1B}[38;2;255;194;72m⏱48m"))
        let (_, sketchy) = run(["statusline", "--format", "sketchybar"], url: url, env: [:])
        #expect(!sketchy.contains("\u{1B}[") && !sketchy.contains("#["))
        let (_, one) = run(["statusline", "--format", "plain", "--provider", "codex"], url: url)
        #expect(one == "Codex 🟨🟨🟨⬛⬛ 59%")
    }

    @Test func noSnapshotExitsThree() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        #expect(run([], url: url).0 == 3)
        #expect(run(["--json"], url: url).0 == 3)
        #expect(run(["statusline"], url: url).0 == 3)
        #expect(run(["wait"], url: url).0 == 3)
    }

    @Test func waitReturnsImmediatelyWhenNotBlocked() throws {
        let url = try write(snapshot())
        let (code, out) = run(["wait", "--json"], url: url)
        #expect(code == 0)
        #expect(out.contains(#""blocked_by":null"#))
    }

    @Test func waitTimesOutWhileBlocked() throws {
        let url = try write(snapshot(blocked: true, sessionUsed: 1))
        var lines: [String] = []
        let start = Date()
        let code = HeadroomCLI.run(["wait", "--provider", "claude", "--timeout", "1s", "--json"], environment: ["NO_COLOR": "1"],
                                   output: { lines.append($0) }, snapshotURL: url, now: Date.init)
        #expect(code == 2)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(lines.first?.contains(#""blocked_by":"session""#) == true)
    }

    @Test func waitWakesWhenTheSnapshotClearsTheBlock() throws {
        let url = try write(snapshot(blocked: true, sessionUsed: 1))
        let unblocked = snapshot()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            var s = unblocked
            s.generatedAt = Date()
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp")
            try? SnapshotFile.encoder().encode(s).write(to: tmp)
            _ = rename(tmp.path, url.path)
        }
        var lines: [String] = []
        let code = HeadroomCLI.run(["wait", "--provider", "claude", "--timeout", "10s"], environment: ["NO_COLOR": "1"],
                                   output: { lines.append($0) }, snapshotURL: url, now: Date.init)
        #expect(code == 0)
        #expect(lines.first?.contains("waiting on the 5-hour session") == true)
    }

    @Test func waitAnyNeedsEveryProviderBlocked() throws {
        let url = try write(snapshot(blocked: true, sessionUsed: 1))
        #expect(run(["wait", "--timeout", "1s"], url: url).0 == 0) // Codex still has capacity
    }

    @Test func usageAndBadFlags() throws {
        let url = try write(snapshot())
        #expect(run(["--help"], url: url).1.contains("usage: headroom"))
        #expect(run(["frobnicate"], url: url).0 == 64)
        #expect(run(["wait", "--timeout", "soon"], url: url).0 == 64)
    }

    @Test func snapshotStaysSmall() throws {
        let data = try SnapshotFile.encoder().encode(snapshot())
        #expect(data.count <= 4096)
    }
}
