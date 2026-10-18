import Foundation
import HeadroomKit

/// Fixed-size little-endian records for the event ledger, so `state.plist` stays one compact blob
/// instead of thousands of dictionaries.
enum LedgerCodec {
    /// keyHash 8 · timestamp 8 · slot 4 · file 4 · model 2 · project 2 · provider 1 · speed 1 · priced 1 · pad 1
    /// · tokens 5×8 · cost 4×8
    static let recordSize = 8 + 8 + 4 + 4 + 2 + 2 + 1 + 1 + 1 + 1 + 40 + 32
    static let magic: UInt32 = 0x4C47_5231 // "LGR1"

    static func encode(_ entries: [Contribution]) -> Data {
        var data = Data(capacity: 4 + entries.count * recordSize)
        func put<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        put(magic)
        for c in entries.sorted(by: { $0.keyHash < $1.keyHash }) {
            put(c.keyHash)
            put(c.timestamp.bitPattern)
            put(c.slot)
            put(c.file)
            put(c.model)
            put(c.project)
            put(UInt8(c.provider == .claude ? 0 : 1))
            put(UInt8(c.speed == .standard ? 0 : c.speed == .fast ? 1 : 2))
            put(UInt8(c.priced ? 1 : 0))
            put(UInt8(0))
            put(c.tokens.newInput); put(c.tokens.cacheWrite5m); put(c.tokens.cacheWrite1h)
            put(c.tokens.cacheRead); put(c.tokens.output)
            put(c.cost.input); put(c.cost.cacheWrite); put(c.cost.cacheRead); put(c.cost.output)
        }
        return data
    }

    static func decode(_ data: Data) -> [Contribution] {
        guard data.count >= 4 else { return [] }
        return data.withUnsafeBytes { raw -> [Contribution] in
            guard raw.loadUnaligned(as: UInt32.self).littleEndian == magic else { return [] }
            let n = (raw.count - 4) / recordSize
            var out: [Contribution] = []
            out.reserveCapacity(n)
            var o = 4
            func get<T: FixedWidthInteger>(_: T.Type) -> T {
                let v = T(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: T.self))
                o += MemoryLayout<T>.size
                return v
            }
            for _ in 0..<n {
                let keyHash = get(UInt64.self)
                let ts = Double(bitPattern: get(UInt64.self))
                let slot = get(Int32.self)
                let file = get(UInt32.self)
                let model = get(UInt16.self)
                let project = get(UInt16.self)
                let provider: Provider = get(UInt8.self) == 0 ? .claude : .codex
                let speedRaw = get(UInt8.self)
                let priced = get(UInt8.self) == 1
                _ = get(UInt8.self)
                let tokens = TokenCounts(newInput: get(Int64.self), cacheWrite5m: get(Int64.self),
                                         cacheWrite1h: get(Int64.self), cacheRead: get(Int64.self), output: get(Int64.self))
                let cost = ClassCost(input: get(Int64.self), cacheWrite: get(Int64.self),
                                     cacheRead: get(Int64.self), output: get(Int64.self))
                out.append(Contribution(
                    keyHash: keyHash, provider: provider, slot: slot, model: model, project: project, file: file,
                    timestamp: ts, tokens: tokens, speed: speedRaw == 0 ? .standard : speedRaw == 1 ? .fast : .ultrafast,
                    cost: cost, priced: priced))
            }
            return out
        }
    }
}
