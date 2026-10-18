import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

@Suite("Store")
struct StoreTests {
    @Test func ledgerCodecRoundTrips() {
        let entries = [
            Contribution(keyHash: 1, provider: .claude, slot: 100, model: 2, project: 3, file: 4, timestamp: 1.5,
                         tokens: TokenCounts(newInput: 1, cacheWrite5m: 2, cacheWrite1h: 3, cacheRead: 4, output: 5),
                         speed: .fast, cost: ClassCost(input: 6, cacheWrite: 7, cacheRead: 8, output: 9), priced: true),
            Contribution(keyHash: .max, provider: .codex, slot: -1, model: 0, project: 0, file: 0, timestamp: 0,
                         tokens: .zero, speed: .ultrafast, cost: .zero, priced: false),
        ]
        let decoded = LedgerCodec.decode(LedgerCodec.encode(entries))
        #expect(Set(decoded) == Set(entries))
        #expect(LedgerCodec.decode(Data([1, 2, 3])).isEmpty)
    }

    @Test func restoredStateNeedsNoRescan() async throws {
        let home = try TempHome()
        try home.copyFixture("claude-main.jsonl", to: ".claude/projects/p-a/main.jsonl")
        try home.copyFixture("codex-rollout-new.jsonl.zst", to: ".codex/sessions/2026/10/01/r.jsonl.zst")
        let first = ingestor(home)
        _ = await first.scanAll()
        let before = await total(first)

        let store = PlistStore<IngestState>(url: home.url.appendingPathComponent("support/state.plist"))
        try store.save(await first.exportState())
        let loaded = try #require(store.load())

        let second = ingestor(home, state: loaded)
        #expect(await total(second) == before)
        #expect(await second.passiveLimits() == (await first.passiveLimits()))
        let r = await second.scanAll()
        #expect(r.filesRead == 0)
        #expect(await total(second) == before)
    }

    @Test func debouncedSaverCoalescesAndFlushes() async throws {
        let count = Mutexed(0)
        let saver = DebouncedSaver(delay: .milliseconds(150)) { count.mutate { $0 += 1 } }
        await saver.schedule()
        await saver.schedule()
        await saver.schedule()
        #expect(await saver.isPending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(count.value == 1)
        await saver.schedule()
        await saver.flush()
        #expect(count.value == 2)
        #expect(!(await saver.isPending))
    }

    @Test func missingOrCorruptFileLoadsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PlistStore<IngestState>(url: dir.appendingPathComponent("state.plist"))
        #expect(store.load() == nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load() == nil)
    }
}
