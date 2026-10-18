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

    init() {}

    var count: Int { sorted.count + overflow.count }

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
            return index(of: h).map { sorted[$0].contribution }
        }
        set {
            if let newValue {
                let p = Packed(newValue)
                if let i = index(of: h) { sorted[i] = p } else {
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
        if let o = overflow.removeValue(forKey: h) { return o.contribution }
        guard let i = index(of: h) else { return nil }
        return sorted.remove(at: i).contribution
    }

    var values: [Contribution] {
        sorted.map(\.contribution) + overflow.values.map(\.contribution)
    }

    /// Removes every record matching `predicate` and returns them.
    mutating func removeAll(where predicate: (Contribution) -> Bool) -> [Contribution] {
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
        merge()
        for i in sorted.indices {
            var c = sorted[i].contribution
            body(&c)
            sorted[i] = Packed(c)
        }
    }

    mutating func merge() {
        guard !overflow.isEmpty else { return }
        sorted.append(contentsOf: overflow.values)
        overflow = [:]
        sorted.sort { $0.keyHash < $1.keyHash }
    }

    /// Builds from records in bulk (decode path), reserving exactly.
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
