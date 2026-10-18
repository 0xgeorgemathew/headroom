import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

/// A throwaway home with `.claude/projects` and `.codex/sessions`.
final class TempHome: @unchecked Sendable {
    let url: URL
    var roots: LogRoots { .standard(home: url) }
    var claude: URL { url.appendingPathComponent(".claude/projects") }
    var codex: URL { url.appendingPathComponent(".codex/sessions") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".claude/projects/p"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".codex/sessions/2026/10/10"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relative: String, _ text: String) throws {
        let u = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    func append(_ relative: String, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    func copyFixture(_ name: String, to relative: String) throws {
        let dst = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FixturePath.url("logs/" + name), to: dst)
    }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }
}

let fixedNow = Date(timeIntervalSince1970: 1_792_400_000) // 2026-10-19
let flatPricer: EventPricer = { e in
    // $1 per million tokens of every class, so cost is easy to check. "glm" is unpriced.
    if e.model.hasPrefix("glm") { return .unpriced }
    return EventPrice(cost: ClassCost(input: e.tokens.newInput, cacheWrite: e.tokens.cacheWrite,
                                      cacheRead: e.tokens.cacheRead, output: e.tokens.output), priced: true)
}

func ingestor(_ home: TempHome, state: IngestState? = nil) -> LogIngestor {
    LogIngestor(roots: home.roots, pricer: flatPricer, state: state, now: { fixedNow })
}

func total(_ i: LogIngestor, _ p: Provider? = nil) async -> UsageTotals {
    await i.buckets().totals(p, from: .distantPast, to: .distantFuture)
}

@Suite("Log tailer")
struct TailerTests {
    @Test func fixtureHomeMatchesReferenceParser() async throws {
        let home = try TempHome()
        try home.copyFixture("claude-main.jsonl", to: ".claude/projects/p-a/main.jsonl")
        try home.copyFixture("claude-subagent.jsonl", to: ".claude/projects/p-a/sess/subagents/agent-1.jsonl")
        try home.copyFixture("claude-special.jsonl", to: ".claude/projects/p-a/special.jsonl")
        try home.copyFixture("codex-rollout-new.jsonl", to: ".codex/sessions/2026/10/01/rollout-new.jsonl")
        try home.copyFixture("codex-rollout-legacy.jsonl", to: ".codex/sessions/2026/10/01/rollout-legacy.jsonl")
        let i = ingestor(home)
        let report = await i.scanAll()
        #expect(report.errors.isEmpty)
        // Values from Scripts/reference_parser.py over the same files.
        let c = await total(i, .claude)
        #expect(c.tokens == TokenCounts(newInput: 160_994, cacheWrite5m: 26_776, cacheWrite1h: 48_963, cacheRead: 111_649, output: 19_308))
        #expect(c.events == 7)
        let x = await total(i, .codex)
        #expect(x.tokens == TokenCounts(newInput: 333_216, cacheRead: 3_483_520, output: 28_633))
        #expect(x.events == 40)
        // glm models are counted but unpriced.
        #expect(c.unpricedTokens == 75_132 + 9_664 + 210 + 85_852 + 290)
        #expect(await i.passiveLimits()?.planType == "self_serve_business_prolite")
    }

    @Test func tailsOnlyAppendedCompleteLines() async throws {
        let home = try TempHome()
        let rel = ".claude/projects/p/s.jsonl"
        try home.write(rel, claudeLine(id: "a", output: 10) + "\n")
        let i = ingestor(home)
        _ = await i.scanAll()
        #expect(await total(i).tokens.output == 10)

        // A partial trailing line is not consumed…
        let second = claudeLine(id: "b", output: 20)
        try home.append(rel, String(second.prefix(40)))
        _ = await i.ingest(paths: [home.path(rel)])
        #expect(await total(i).events == 1)
        // …until it is completed.
        try home.append(rel, String(second.dropFirst(40)) + "\n")
        let r = await i.ingest(paths: [home.path(rel)])
        #expect(r.eventsAdded == 1)
        #expect(await total(i).tokens.output == 30)
        // Nothing new: nothing read.
        let again = await i.ingest(paths: [home.path(rel)])
        #expect(again.filesRead == 0)
    }

    @Test func laterLineSupersedesSameKey() async throws {
        let home = try TempHome()
        let rel = ".claude/projects/p/s.jsonl"
        try home.write(rel, claudeLine(id: "m", output: 10) + "\n")
        let i = ingestor(home)
        _ = await i.scanAll()
        try home.append(rel, claudeLine(id: "m", output: 55) + "\n")
        _ = await i.ingest(paths: [home.path(rel)])
        let t = await total(i)
        #expect(t.events == 1)
        #expect(t.tokens.output == 55)
        #expect(t.cost.output == 55)
    }

    @Test func crossFileDuplicateKeepsLaterTimestamp() async throws {
        let home = try TempHome()
        try home.write(".claude/projects/p/a.jsonl", claudeLine(id: "m", ts: "2026-10-17T10:00:00Z", output: 10) + "\n")
        try home.write(".claude/projects/p/z.jsonl", claudeLine(id: "m", ts: "2026-10-17T10:01:00Z", output: 99) + "\n")
        let i = ingestor(home)
        _ = await i.scanAll()
        #expect(await total(i).tokens.output == 99)
    }

    @Test func truncationAndInodeChangeRereadFile() async throws {
        let home = try TempHome()
        let rel = ".claude/projects/p/s.jsonl"
        try home.write(rel, claudeLine(id: "a", output: 10) + "\n" + claudeLine(id: "b", output: 20) + "\n")
        let i = ingestor(home)
        _ = await i.scanAll()
        #expect(await total(i).tokens.output == 30)
        // Replace the file (new inode) with a rewritten history: same keys are replaced, not doubled.
        try FileManager.default.removeItem(atPath: home.path(rel))
        try home.write(rel, claudeLine(id: "a", output: 11) + "\n")
        _ = await i.ingest(paths: [home.path(rel)])
        #expect(await total(i).tokens.output == 31)
        // Shrinking in place (same inode) also re-reads from the start.
        try Data().write(to: URL(fileURLWithPath: home.path(rel)))
        try home.append(rel, claudeLine(id: "c", output: 1) + "\n")
        _ = await i.ingest(paths: [home.path(rel)])
        #expect(await total(i).tokens.output == 32)
    }

    @Test func compressedRolloutResumesWithoutDoubleCounting() async throws {
        let home = try TempHome()
        let full = try String(contentsOf: FixturePath.url("logs/codex-rollout-new.jsonl"), encoding: .utf8)
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        let half = lines.prefix(lines.count / 2).joined(separator: "\n") + "\n"
        let rel = ".codex/sessions/2026/10/10/rollout-x.jsonl"
        try home.write(rel, half)
        let i = ingestor(home)
        _ = await i.scanAll()
        let partial = await total(i, .codex)
        #expect(partial.events > 0 && partial.events < 40)

        // Codex compresses the finished rollout: the plain file disappears, the .zst appears.
        try FileManager.default.removeItem(atPath: home.path(rel))
        try FileManager.default.copyItem(at: FixturePath.url("logs/codex-rollout-new.jsonl.zst"),
                                         to: URL(fileURLWithPath: home.path(rel + ".zst")))
        _ = await i.scanAll()
        let after = await total(i, .codex)
        #expect(after.events == 40)
        #expect(after.tokens == TokenCounts(newInput: 333_216, cacheRead: 3_483_520, output: 28_633))
        // Immutable once consumed.
        let again = await i.scanAll()
        #expect(again.filesRead == 0)
    }

    @Test func plainFileWinsWhileBothFormsExist() async throws {
        let home = try TempHome()
        try home.copyFixture("codex-rollout-new.jsonl", to: ".codex/sessions/2026/10/10/r.jsonl")
        try home.copyFixture("codex-rollout-new.jsonl.zst", to: ".codex/sessions/2026/10/10/r.jsonl.zst")
        let i = ingestor(home)
        let r = await i.scanAll()
        #expect(r.filesRead == 1)
        #expect(await total(i, .codex).events == 40)
    }

    @Test func oldFilesAndEventsOutsideRetentionAreSkipped() async throws {
        let home = try TempHome()
        let rel = ".claude/projects/p/old.jsonl"
        try home.write(rel, claudeLine(id: "a", output: 10) + "\n")
        let old = fixedNow.addingTimeInterval(-40 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.path(rel))
        // An event older than the window inside a fresh file is pruned.
        try home.write(".claude/projects/p/new.jsonl",
                       claudeLine(id: "b", ts: "2026-08-01T00:00:00Z", output: 5) + "\n" + claudeLine(id: "c", output: 7) + "\n")
        let i = ingestor(home)
        let r = await i.scanAll()
        #expect(r.filesRead == 1)
        #expect(await total(i).tokens.output == 7)
    }

    @Test func ingestIgnoresPathsOutsideRoots() async throws {
        let home = try TempHome()
        let i = ingestor(home)
        let r = await i.ingest(paths: ["/tmp/elsewhere/x.jsonl", home.path(".claude/projects/p/missing.jsonl")])
        #expect(r.filesRead == 0)
    }

    @Test func watcherReportsChangedLogs() async throws {
        let home = try TempHome()
        let seen = Mutexed<[String]>([])
        let watcher = LogWatcher(roots: [home.claude], latency: 0.1) { paths, _ in seen.mutate { $0 += paths } }
        #expect(watcher.start())
        try await Task.sleep(for: .milliseconds(300))
        try home.write(".claude/projects/p/w.jsonl", claudeLine() + "\n")
        for _ in 0..<50 where seen.value.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        watcher.stop()
        #expect(seen.value.contains { $0.hasSuffix("/p/w.jsonl") })
    }
}

final class Mutexed<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
