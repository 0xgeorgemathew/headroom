import Foundation
import HeadroomKit

/// Compact storage for the event ledger: packed 72-byte records sorted by key hash, plus a small
/// overflow map for recent inserts. Replaces `[UInt64: Contribution]` (~4× smaller), which matters
/// because the ledger is the largest thing the idle app keeps in memory.
struct ContributionTable: Sendable {
    struct Packed: Sendable {
        var keyHash: UInt64
        var timestamp: Double
        var slot: Int32
        var file: UInt32
        var model: UInt16
        var project: UInt16
        /// bit 0: provider (1 = codex), bit 1: priced, bits 2–3: speed
        var flags: UInt8
        var newInput: UInt32, cacheWrite5m: UInt32, cacheWrite1h: UInt32, cacheRead: UInt32, output: UInt32
        var costInput: Int32, costCacheWrite: Int32, costCacheRead: Int32, costOutput: Int32

        init(_ c: Contribution) {
            keyHash = c.keyHash
            timestamp = c.timestamp
            slot = c.slot
            file = c.file
            model = c.model
            project = c.project
            let speedBits: UInt8 = switch c.speed { case .standard: 0; case .fast: 1; case .ultrafast: 2 }
            flags = (c.provider == .codex ? 1 : 0) | (c.priced ? 2 : 0) | (speedBits << 2)
            newInput = UInt32(clamping: c.tokens.newInput)
            cacheWrite5m = UInt32(clamping: c.tokens.cacheWrite5m)
            cacheWrite1h = UInt32(clamping: c.tokens.cacheWrite1h)
            cacheRead = UInt32(clamping: c.tokens.cacheRead)
            output = UInt32(clamping: c.tokens.output)
            costInput = Int32(clamping: c.cost.input)
            costCacheWrite = Int32(clamping: c.cost.cacheWrite)
            costCacheRead = Int32(clamping: c.cost.cacheRead)
            costOutput = Int32(clamping: c.cost.output)
        }

        var contribution: Contribution {
            let speed: Speed = switch (flags >> 2) & 3 { case 1: .fast; case 2: .ultrafast; default: .standard }
            return Contribution(
                keyHash: keyHash, provider: flags & 1 == 1 ? .codex : .claude, slot: slot, model: model, project: project,
                file: file, timestamp: timestamp,
                tokens: TokenCounts(newInput: Int64(newInput), cacheWrite5m: Int64(cacheWrite5m), cacheWrite1h: Int64(cacheWrite1h),
                                    cacheRead: Int64(cacheRead), output: Int64(output)),
                speed: speed,
                cost: ClassCost(input: Int64(costInput), cacheWrite: Int64(costCacheWrite), cacheRead: Int64(costCacheRead), output: Int64(costOutput)),
                priced: flags & 2 == 2
            )
        }
    }

    private var sorted: [Packed] = []
    private var overflow: [UInt64: Packed] = [:]
    private static let mergeThreshold = 2048

    /// Read-only, file-backed base records (the parent app). Clean mapped pages don't count
    /// toward the process footprint; changes live in `overflow` and `removed` until the next save.
    private var mapped: MappedLedger?
    private var removed: Set<UInt64> = []
    /// Overflow keys that shadow a mapped record (so `count` stays exact).
    private var shadowing = 0

    init() {}

    /// Maps a ledger file written by `LedgerCodec.encode`. Nil when the file is unusable.
    init?(mappedFile url: URL) {
        guard let m = MappedLedger(url: url) else { return nil }
        mapped = m
    }

    var isMapped: Bool { mapped != nil }

    var count: Int {
        guard let mapped else { return sorted.count + overflow.count }
        return mapped.count - removed.count + overflow.count - shadowing
    }

    /// Converts a mapped table to plain in-memory storage (rare: prune, reprice).
    private mutating func materialize() {
        guard let m = mapped else { return }
        var all: [Packed] = []
        all.reserveCapacity(m.count)
        for i in 0..<m.count where !removed.contains(m.keyHash(at: i)) { all.append(m.packed(at: i)) }
        let pending = overflow
        mapped = nil
        removed = []
        shadowing = 0
        overflow = [:]
        sorted = all
        for (h, p) in pending { if let i = index(of: h) { sorted[i] = p } else { overflow[h] = p } }
        merge()
    }

    private func index(of h: UInt64) -> Int? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].keyHash < h { lo = mid + 1 } else { hi = mid }
        }
        return lo < sorted.count && sorted[lo].keyHash == h ? lo : nil
    }

    subscript(h: UInt64) -> Contribution? {
        get {
            if let o = overflow[h] { return o.contribution }
            if let m = mapped {
                guard !removed.contains(h), let i = m.index(of: h) else { return nil }
                return m.packed(at: i).contribution
            }
            return index(of: h).map { sorted[$0].contribution }
        }
        set {
            if let newValue {
                let p = Packed(newValue)
                if let m = mapped {
                    if overflow[h] == nil, !removed.contains(h), m.index(of: h) != nil { shadowing += 1 }
                    if removed.remove(h) != nil { shadowing += 1 }
                    overflow[h] = p
                } else if let i = index(of: h) { sorted[i] = p } else {
                    overflow[h] = p
                    if overflow.count >= Self.mergeThreshold { merge() }
                }
            } else {
                _ = removeValue(forKey: h)
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey h: UInt64) -> Contribution? {
        if let m = mapped {
            let inBase = !removed.contains(h) && m.index(of: h) != nil
            if let o = overflow.removeValue(forKey: h) {
                if inBase { shadowing -= 1; removed.insert(h) }
                return o.contribution
            }
            guard inBase, let i = m.index(of: h) else { return nil }
            removed.insert(h)
            return m.packed(at: i).contribution
        }
        if let o = overflow.removeValue(forKey: h) { return o.contribution }
        guard let i = index(of: h) else { return nil }
        return sorted.remove(at: i).contribution
    }

    var values: [Contribution] {
        var out: [Contribution] = []
        out.reserveCapacity(count)
        forEachPacked { out.append($0.contribution) }
        return out
    }

    /// Removes every record matching `predicate` and returns them.
    mutating func removeAll(where predicate: (Contribution) -> Bool) -> [Contribution] {
        materialize()
        merge()
        var removed: [Contribution] = []
        sorted.removeAll { p in
            let c = p.contribution
            if predicate(c) { removed.append(c); return true }
            return false
        }
        return removed
    }

    /// Rewrites every record in place.
    mutating func update(_ body: (inout Contribution) -> Void) {
        materialize()
        merge()
        for i in sorted.indices {
            var c = sorted[i].contribution
            body(&c)
            sorted[i] = Packed(c)
        }
    }

    mutating func merge() {
        guard mapped == nil, !overflow.isEmpty else { return }
        sorted.append(contentsOf: overflow.values)
        overflow = [:]
        sorted.sort { $0.keyHash < $1.keyHash }
    }

    /// Builds from packed records (decode path). Sorts and collapses duplicates when needed.
    init(packed: [Packed]) {
        sorted = packed
        if !zip(sorted, sorted.dropFirst()).allSatisfy({ $0.keyHash < $1.keyHash }) {
            sorted.sort { $0.keyHash < $1.keyHash }
            var deduped: [Packed] = []
            deduped.reserveCapacity(sorted.count)
            for p in sorted {
                if let last = deduped.last, last.keyHash == p.keyHash { deduped[deduped.count - 1] = p } else { deduped.append(p) }
            }
            sorted = deduped
        }
    }

    /// Visits every record in key order (merging the sorted base with the sorted overflow keys).
    func forEachPackedSorted(_ body: (Packed) -> Void) {
        let extra = overflow.keys.sorted()
        var j = 0
        func drainExtra(below h: UInt64?) {
            while j < extra.count, h.map({ extra[j] < $0 }) ?? true { body(overflow[extra[j]]!); j += 1 }
        }
        if let m = mapped {
            for i in 0..<m.count {
                let h = m.keyHash(at: i)
                drainExtra(below: h)
                if removed.contains(h) || overflow[h] != nil { continue }
                body(m.packed(at: i))
            }
        } else {
            for p in sorted {
                drainExtra(below: p.keyHash)
                if overflow[p.keyHash] != nil { continue }
                body(p)
            }
        }
        drainExtra(below: nil)
    }

    /// Visits every record without materializing an array (sorted part, then recent inserts).
    func forEachPacked(_ body: (Packed) -> Void) {
        if let m = mapped {
            for i in 0..<m.count {
                let h = m.keyHash(at: i)
                if removed.contains(h) || overflow[h] != nil { continue }
                body(m.packed(at: i))
            }
        } else {
            for p in sorted { body(p) }
        }
        for p in overflow.values { body(p) }
    }

    /// Builds from records in bulk, reserving exactly.
    init(_ contributions: [Contribution]) {
        sorted.reserveCapacity(contributions.count)
        for c in contributions { sorted.append(Packed(c)) }
        sorted.sort { $0.keyHash < $1.keyHash }
        // Collapse duplicates (last wins), matching dictionary insertion semantics.
        var deduped: [Packed] = []
        deduped.reserveCapacity(sorted.count)
        for p in sorted {
            if let last = deduped.last, last.keyHash == p.keyHash { deduped[deduped.count - 1] = p } else { deduped.append(p) }
        }
        sorted = deduped
    }
}


/// A ledger file (`LedgerCodec` record format) mapped read-only.
final class MappedLedger: @unchecked Sendable {
    private let base: UnsafeMutableRawPointer
    private let length: Int
    let count: Int

    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 4 else { return nil }
        length = Int(st.st_size)
        guard let p = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        base = p
        let raw = UnsafeRawBufferPointer(start: p, count: length)
        guard raw.loadUnaligned(as: UInt32.self).littleEndian == LedgerCodec.magic else {
            munmap(p, length)
            return nil
        }
        count = (length - 4) / LedgerCodec.recordSize
        // Records must be sorted by key for binary search; the encoder writes them that way.
        for i in 1..<max(count, 1) where keyHash(at: i - 1) >= keyHash(at: i) {
            munmap(p, length)
            return nil
        }
    }

    deinit { munmap(base, length) }

    private var raw: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: length) }

    func keyHash(at i: Int) -> UInt64 {
        UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 4 + i * LedgerCodec.recordSize, as: UInt64.self))
    }

    func packed(at i: Int) -> ContributionTable.Packed { LedgerCodec.packed(raw, at: 4 + i * LedgerCodec.recordSize) }

    func index(of h: UInt64) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyHash(at: mid) < h { lo = mid + 1 } else { hi = mid }
        }
        return lo < count && keyHash(at: lo) == h ? lo : nil
    }
}
