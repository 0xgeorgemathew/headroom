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

@Suite struct PackedLedgerCodecTests {
    @Test func tableRoundTripsThroughTheRecordFormat() {
        var table = ContributionTable()
        for i in 0..<5000 {
            let c = Contribution(keyHash: UInt64(i) &* 0x9E37_79B9_7F4A_7C15, provider: i % 2 == 0 ? .claude : .codex,
                                 slot: Int32(i), model: UInt16(i % 7), project: UInt16(i % 3), file: UInt32(i % 11),
                                 timestamp: 1_790_000_000 + Double(i), tokens: TokenCounts(newInput: Int64(i), cacheWrite5m: 2, cacheWrite1h: 3, cacheRead: 40_000, output: 7),
                                 speed: i % 5 == 0 ? .fast : .standard, cost: ClassCost(input: 10, cacheWrite: 20, cacheRead: 30, output: Int64(i)), priced: i % 4 != 0)
            table[c.keyHash] = c
        }
        let decoded = LedgerCodec.decodeTable(LedgerCodec.encode(table))
        #expect(decoded.count == 5000)
        let a = table.values.sorted { $0.keyHash < $1.keyHash }
        let b = decoded.values.sorted { $0.keyHash < $1.keyHash }
        #expect(a == b)
        // Same bytes as the array-based encoder (format compatibility).
        #expect(LedgerCodec.decode(LedgerCodec.encode(table)).sorted { $0.keyHash < $1.keyHash } == a)
    }
}

@Suite struct MappedLedgerTests {
    func contribution(_ i: Int, output: Int64 = 7) -> Contribution {
        Contribution(keyHash: UInt64(i) &* 0x9E37_79B9_7F4A_7C15, provider: .claude, slot: Int32(i), model: 0, project: 0, file: 0,
                     timestamp: 1_790_000_000 + Double(i), tokens: TokenCounts(newInput: Int64(i), output: output),
                     speed: .standard, cost: ClassCost(input: 1, output: 2), priced: true)
    }

    @Test func mappedTableBehavesLikeTheInMemoryOne() throws {
        var table = ContributionTable()
        for i in 0..<3000 { let c = contribution(i); table[c.keyHash] = c }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).bin")
        try LedgerCodec.encode(table).write(to: url)
        var mapped = try #require(ContributionTable(mappedFile: url))
        #expect(mapped.isMapped && mapped.count == 3000)
        // Lookup, update (shadow), insert, remove — mirrored on the in-memory table.
        let a = contribution(10), b = contribution(10, output: 99), c = contribution(5000)
        #expect(mapped[a.keyHash] == a)
        mapped[b.keyHash] = b; table[b.keyHash] = b
        mapped[c.keyHash] = c; table[c.keyHash] = c
        _ = mapped.removeValue(forKey: contribution(20).keyHash); _ = table.removeValue(forKey: contribution(20).keyHash)
        #expect(mapped[b.keyHash] == b)
        #expect(mapped[contribution(20).keyHash] == nil)
        #expect(mapped.count == table.count)
        #expect(mapped.values.sorted { $0.keyHash < $1.keyHash } == table.values.sorted { $0.keyHash < $1.keyHash })
        // Re-encoding a mapped table with changes stays sorted and maps again.
        let url2 = url.appendingPathExtension("2")
        try LedgerCodec.encode(mapped).write(to: url2)
        let remapped = try #require(ContributionTable(mappedFile: url2))
        #expect(remapped.count == table.count)
        // Prune materializes.
        var pruned = remapped
        let gone = pruned.removeAll { $0.timestamp < 1_790_000_100 }
        #expect(gone.count == 99) // keys 0..<100 except the removed 20
        #expect(!pruned.isMapped)
    }

    @Test func unsortedOrCorruptFilesAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-bad-\(UUID().uuidString).bin")
        try Data([1, 2, 3, 4, 5]).write(to: url)
        #expect(ContributionTable(mappedFile: url) == nil)
    }
}
