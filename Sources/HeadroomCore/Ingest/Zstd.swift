import Foundation

/// Errors from the zstd decoder. Corrupt input always throws; it never traps.
public enum ZstdError: Error, Equatable, CustomStringConvertible, Sendable {
    case notZstd
    case unsupported(String)
    case corrupt(String)
    case truncated
    case checksumMismatch

    public var description: String {
        switch self {
        case .notZstd: "not a zstd stream"
        case .unsupported(let s): "unsupported zstd feature: \(s)"
        case .corrupt(let s): "corrupt zstd data: \(s)"
        case .truncated: "truncated zstd data"
        case .checksumMismatch: "zstd content checksum mismatch"
        }
    }
}

/// A pure-Swift Zstandard decoder (RFC 8878). Codex compresses rollouts older than about
/// ten days to `*.jsonl.zst`; Apple's Compression framework has no zstd (PLAN §14.3).
///
/// Supports every frame feature a standard encoder emits except dictionaries:
/// raw/RLE/compressed blocks, raw/RLE/Huffman (1 and 4 stream, treeless) literals,
/// predefined/RLE/FSE/repeat sequence tables, repeat offsets, content checksums,
/// skippable frames and concatenated frames.
public enum Zstd {
    public static let frameMagic: UInt32 = 0xFD2F_B528

    /// True when the buffer starts with a zstd or skippable frame magic.
    public static func isZstd(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return m == frameMagic || (m & 0xFFFF_FFF0) == 0x184D_2A50
    }

    /// Decodes every frame in `data`.
    public static func decompress(_ data: Data, verifyChecksum: Bool = true) throws -> Data {
        try data.withUnsafeBytes { raw in
            try decompress(raw, verifyChecksum: verifyChecksum)
        }
    }

    public static func decompress(_ raw: UnsafeRawBufferPointer, verifyChecksum: Bool = true) throws -> Data {
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count > 0 else {
            throw ZstdError.notZstd
        }
        let decoder = ZstdDecoder(verifyChecksum: verifyChecksum)
        return try decoder.decodeAll(base, raw.count)
    }
}

// MARK: - Output buffer

/// Growable malloc'd output that hands its bytes to `Data` without copying.
final class ZstdOutput {
    var base: UnsafeMutablePointer<UInt8>
    var count = 0
    private(set) var capacity: Int
    private var owned = true
    /// Slack after `capacity` so match copies may write a few bytes past the end.
    static let slack = 64

    init(capacity: Int) {
        let cap = max(capacity, 4096)
        self.capacity = cap
        base = malloc(cap + Self.slack)!.assumingMemoryBound(to: UInt8.self)
    }

    deinit { if owned { free(base) } }

    @inline(__always) func ensure(_ extra: Int) {
        if count + extra > capacity { grow(count + extra) }
    }

    private func grow(_ needed: Int) {
        var cap = capacity
        while cap < needed { cap = cap &* 2 }
        base = realloc(base, cap + Self.slack)!.assumingMemoryBound(to: UInt8.self)
        capacity = cap
    }

    func takeData() -> Data {
        owned = false
        if count == 0 {
            free(base)
            return Data()
        }
        return Data(bytesNoCopy: base, count: count, deallocator: .free)
    }
}

// MARK: - Bit readers

/// Backward bit reader (zstd's BIT_DStream): bitstreams are read from the last byte toward the first.
struct BackBits {
    var container: UInt64 = 0
    var consumed: UInt64 = 0
    var ptr: UnsafePointer<UInt8>
    let start: UnsafePointer<UInt8>

    init(_ start: UnsafePointer<UInt8>, _ size: Int) throws {
        guard size > 0 else { throw ZstdError.corrupt("empty bitstream") }
        self.start = start
        let last = start[size - 1]
        guard last != 0 else { throw ZstdError.corrupt("missing bitstream end mark") }
        let highBit = UInt64(7 - last.leadingZeroBitCount)
        if size >= 8 {
            ptr = start + (size - 8)
            container = UnsafeRawPointer(ptr).loadUnaligned(as: UInt64.self)
            consumed = 8 - highBit
        } else {
            ptr = start
            var c: UInt64 = 0
            for i in 0..<size { c |= UInt64(start[i]) << (8 * UInt64(i)) }
            container = c
            consumed = 8 - highBit + UInt64(8 - size) * 8
        }
    }

    @inline(__always) func peek(_ n: Int) -> UInt64 {
        ((container &<< consumed) &>> 1) &>> UInt64(truncatingIfNeeded: 63 - n)
    }

    @inline(__always) mutating func skip(_ n: Int) { consumed &+= UInt64(truncatingIfNeeded: n) }

    @inline(__always) mutating func read(_ n: Int) -> Int {
        let v = peek(n)
        consumed &+= UInt64(truncatingIfNeeded: n)
        return Int(truncatingIfNeeded: v)
    }

    @inline(__always) mutating func reload() {
        if consumed > 64 { return }
        if ptr >= start + 8 {
            ptr -= Int(consumed >> 3)
            consumed &= 7
            container = UnsafeRawPointer(ptr).loadUnaligned(as: UInt64.self)
        } else if ptr == start {
            return
        } else {
            var nb = Int(consumed >> 3)
            let avail = ptr - start
            if nb > avail { nb = avail }
            ptr -= nb
            consumed -= UInt64(nb * 8)
            container = UnsafeRawPointer(ptr).loadUnaligned(as: UInt64.self)
        }
    }

    /// All bits consumed exactly.
    var finished: Bool { ptr == start && consumed == 64 }
    var overflowed: Bool { consumed > 64 }
}

/// Forward little-endian bit reader for FSE table headers.
struct ForwardBits {
    let base: UnsafePointer<UInt8>
    let size: Int
    var bitPos = 0

    init(_ base: UnsafePointer<UInt8>, _ size: Int) {
        self.base = base
        self.size = size
    }

    mutating func read(_ n: Int) throws -> Int {
        var v = 0
        for i in 0..<n {
            let byte = (bitPos + i) >> 3
            guard byte < size else { throw ZstdError.truncated }
            v |= Int((base[byte] >> UInt8((bitPos + i) & 7)) & 1) << i
        }
        bitPos += n
        return v
    }

    mutating func rewind(_ n: Int) { bitPos -= n }
    var bytesUsed: Int { (bitPos + 7) >> 3 }
}

// MARK: - Decoder

final class ZstdDecoder {
    private let verifyChecksum: Bool

    // FSE decoding tables. Entry = symbol << 24 | nbBits << 16 | baseline.
    private let llTable = UnsafeMutablePointer<UInt32>.allocate(capacity: 512)
    private let ofTable = UnsafeMutablePointer<UInt32>.allocate(capacity: 512)
    private let mlTable = UnsafeMutablePointer<UInt32>.allocate(capacity: 512)
    private var llLog = 0, ofLog = 0, mlLog = 0
    private var haveLL = false, haveOF = false, haveML = false

    // Huffman table: entry = symbol << 8 | nbBits, size 1 << huffBits.
    private let huffTable = UnsafeMutablePointer<UInt16>.allocate(capacity: 1 << 11)
    private var huffBits = 0
    private var haveHuff = false

    private let weightTable = UnsafeMutablePointer<UInt32>.allocate(capacity: 64)
    private let literals = UnsafeMutablePointer<UInt8>.allocate(capacity: (1 << 17) + 64)
    private var rep: (Int, Int, Int) = (1, 4, 8)

    static let maxBlock = 1 << 17

    init(verifyChecksum: Bool) {
        self.verifyChecksum = verifyChecksum
    }

    deinit {
        llTable.deallocate()
        ofTable.deallocate()
        mlTable.deallocate()
        huffTable.deallocate()
        weightTable.deallocate()
        literals.deallocate()
    }

    func decodeAll(_ src: UnsafePointer<UInt8>, _ size: Int) throws -> Data {
        var p = 0
        let out = ZstdOutput(capacity: estimateSize(src, size))
        var frames = 0
        while p < size {
            guard size - p >= 4 else { throw ZstdError.truncated }
            let magic = UnsafeRawPointer(src + p).loadUnaligned(as: UInt32.self)
            p += 4
            if magic == Zstd.frameMagic {
                p = try decodeFrame(src, p, size, out)
                frames += 1
            } else if (magic & 0xFFFF_FFF0) == 0x184D_2A50 {
                guard size - p >= 4 else { throw ZstdError.truncated }
                let len = Int(UnsafeRawPointer(src + p).loadUnaligned(as: UInt32.self))
                p += 4
                guard size - p >= len else { throw ZstdError.truncated }
                p += len
                frames += 1
            } else {
                throw frames == 0 ? ZstdError.notZstd : ZstdError.corrupt("bad frame magic")
            }
        }
        return out.takeData()
    }

    /// Sum of declared frame content sizes, for a single allocation in the common case.
    private func estimateSize(_ src: UnsafePointer<UInt8>, _ size: Int) -> Int {
        guard size >= 6, UnsafeRawPointer(src).loadUnaligned(as: UInt32.self) == Zstd.frameMagic else {
            return size * 4
        }
        let fhd = src[4]
        let fcsFlag = Int(fhd >> 6)
        let single = (fhd >> 5) & 1 == 1
        let dictSize = [0, 1, 2, 4][Int(fhd & 3)]
        let fcsSize = [single ? 1 : 0, 2, 4, 8][fcsFlag]
        let at = 5 + (single ? 0 : 1) + dictSize
        guard fcsSize > 0, size >= at + fcsSize else { return size * 6 }
        var fcs = 0
        for i in 0..<fcsSize { fcs |= Int(src[at + i]) << (8 * i) }
        if fcsSize == 2 { fcs += 256 }
        return min(max(fcs, 0), 1 << 32)
    }

    private func decodeFrame(_ src: UnsafePointer<UInt8>, _ start: Int, _ size: Int, _ out: ZstdOutput) throws -> Int {
        var p = start
        guard p < size else { throw ZstdError.truncated }
        let fhd = src[p]
        p += 1
        let fcsFlag = Int(fhd >> 6)
        let single = (fhd >> 5) & 1 == 1
        guard (fhd >> 3) & 1 == 0 else { throw ZstdError.corrupt("reserved frame header bit") }
        let hasChecksum = (fhd >> 2) & 1 == 1
        let dictSize = [0, 1, 2, 4][Int(fhd & 3)]
        if !single {
            guard p < size else { throw ZstdError.truncated }
            p += 1 // window descriptor: the whole output is kept, so the window needs no tracking
        }
        guard size - p >= dictSize else { throw ZstdError.truncated }
        var dictID = 0
        for i in 0..<dictSize { dictID |= Int(src[p + i]) << (8 * i) }
        p += dictSize
        guard dictID == 0 else { throw ZstdError.unsupported("dictionary") }
        let fcsSize = [single ? 1 : 0, 2, 4, 8][fcsFlag]
        guard size - p >= fcsSize else { throw ZstdError.truncated }
        var contentSize: Int? = nil
        if fcsSize > 0 {
            var v: UInt64 = 0
            for i in 0..<fcsSize { v |= UInt64(src[p + i]) << (8 * UInt64(i)) }
            if fcsSize == 2 { v += 256 }
            guard v < (1 << 40) else { throw ZstdError.unsupported("frame larger than 1 TB") }
            contentSize = Int(v)
            p += fcsSize
        }
        let frameStart = out.count
        if let contentSize { out.ensure(contentSize) }

        rep = (1, 4, 8)
        haveLL = false; haveOF = false; haveML = false; haveHuff = false

        while true {
            guard size - p >= 3 else { throw ZstdError.truncated }
            let h = Int(src[p]) | Int(src[p + 1]) << 8 | Int(src[p + 2]) << 16
            p += 3
            let last = h & 1 == 1
            let type = (h >> 1) & 3
            let bsize = h >> 3
            switch type {
            case 0:
                guard size - p >= bsize else { throw ZstdError.truncated }
                out.ensure(bsize)
                (out.base + out.count).update(from: src + p, count: bsize)
                out.count += bsize
                p += bsize
            case 1:
                guard p < size else { throw ZstdError.truncated }
                guard bsize <= Self.maxBlock else { throw ZstdError.corrupt("RLE block too large") }
                out.ensure(bsize)
                (out.base + out.count).initialize(repeating: src[p], count: bsize)
                out.count += bsize
                p += 1
            case 2:
                guard bsize <= Self.maxBlock else { throw ZstdError.corrupt("block too large") }
                guard size - p >= bsize else { throw ZstdError.truncated }
                try decodeCompressedBlock(src + p, bsize, out, frameStart: frameStart)
                p += bsize
            default:
                throw ZstdError.corrupt("reserved block type")
            }
            if last { break }
        }

        if let contentSize, out.count - frameStart != contentSize {
            throw ZstdError.corrupt("frame content size mismatch")
        }
        if hasChecksum {
            guard size - p >= 4 else { throw ZstdError.truncated }
            if verifyChecksum {
                let expected = UnsafeRawPointer(src + p).loadUnaligned(as: UInt32.self)
                let actual = UInt32(truncatingIfNeeded: XXH64.hash(out.base + frameStart, out.count - frameStart))
                guard expected == actual else { throw ZstdError.checksumMismatch }
            }
            p += 4
        }
        return p
    }

    // MARK: Compressed block

    private func decodeCompressedBlock(_ src: UnsafePointer<UInt8>, _ size: Int, _ out: ZstdOutput, frameStart: Int) throws {
        var p = 0
        let (litPtr, litCount, used) = try decodeLiterals(src, size)
        p += used
        try decodeSequences(src + p, size - p, litPtr, litCount, out, frameStart: frameStart)
    }

    /// Returns a pointer to the regenerated literals (inside `src` for raw literals),
    /// their count, and the bytes of `src` consumed.
    private func decodeLiterals(_ src: UnsafePointer<UInt8>, _ size: Int) throws -> (UnsafePointer<UInt8>, Int, Int) {
        guard size >= 1 else { throw ZstdError.truncated }
        let b0 = Int(src[0])
        let type = b0 & 3
        let sf = (b0 >> 2) & 3
        switch type {
        case 0, 1:
            var regen = 0
            var hdr = 1
            switch sf {
            case 0, 2:
                regen = b0 >> 3
            case 1:
                guard size >= 2 else { throw ZstdError.truncated }
                regen = (b0 >> 4) + (Int(src[1]) << 4)
                hdr = 2
            default:
                guard size >= 3 else { throw ZstdError.truncated }
                regen = (b0 >> 4) + (Int(src[1]) << 4) + (Int(src[2]) << 12)
                hdr = 3
            }
            guard regen <= Self.maxBlock else { throw ZstdError.corrupt("literals too large") }
            if type == 0 {
                guard size - hdr >= regen else { throw ZstdError.truncated }
                return (src + hdr, regen, hdr + regen)
            }
            guard size - hdr >= 1 else { throw ZstdError.truncated }
            literals.initialize(repeating: src[hdr], count: regen)
            return (UnsafePointer(literals), regen, hdr + 1)
        default:
            var regen = 0, comp = 0, hdr = 0
            let four = sf != 0
            switch sf {
            case 0, 1:
                guard size >= 3 else { throw ZstdError.truncated }
                let h = Int(src[0]) | Int(src[1]) << 8 | Int(src[2]) << 16
                regen = (h >> 4) & 0x3FF
                comp = (h >> 14) & 0x3FF
                hdr = 3
            case 2:
                guard size >= 4 else { throw ZstdError.truncated }
                let h = Int(src[0]) | Int(src[1]) << 8 | Int(src[2]) << 16 | Int(src[3]) << 24
                regen = (h >> 4) & 0x3FFF
                comp = (h >> 18) & 0x3FFF
                hdr = 4
            default:
                guard size >= 5 else { throw ZstdError.truncated }
                let h = Int(src[0]) | Int(src[1]) << 8 | Int(src[2]) << 16 | Int(src[3]) << 24 | Int(src[4]) << 32
                regen = (h >> 4) & 0x3FFFF
                comp = (h >> 22) & 0x3FFFF
                hdr = 5
            }
            guard regen <= Self.maxBlock else { throw ZstdError.corrupt("literals too large") }
            guard size - hdr >= comp else { throw ZstdError.truncated }
            var q = src + hdr
            var remain = comp
            if type == 2 {
                let used = try readHuffmanTable(q, remain)
                q += used
                remain -= used
            } else if !haveHuff {
                throw ZstdError.corrupt("treeless literals without a table")
            }
            if four {
                try decodeHuffman4(q, remain, regen)
            } else {
                try decodeHuffman1(q, remain, literals, regen)
            }
            return (UnsafePointer(literals), regen, hdr + comp)
        }
    }

    // MARK: Huffman

    private func readHuffmanTable(_ src: UnsafePointer<UInt8>, _ size: Int) throws -> Int {
        guard size >= 1 else { throw ZstdError.truncated }
        let header = Int(src[0])
        var weights = [UInt8](repeating: 0, count: 256)
        var nWeights = 0
        var used = 0
        if header >= 128 {
            nWeights = header - 127
            let bytes = (nWeights + 1) / 2
            guard size - 1 >= bytes else { throw ZstdError.truncated }
            for i in 0..<nWeights {
                let byte = src[1 + i / 2]
                weights[i] = i % 2 == 0 ? byte >> 4 : byte & 0xF
            }
            used = 1 + bytes
        } else {
            guard size - 1 >= header, header > 0 else { throw ZstdError.truncated }
            var fb = ForwardBits(src + 1, header)
            let log = try readFSEHeader(&fb, maxLog: 6, maxSymbol: 255, into: weightTable)
            let hsize = fb.bytesUsed
            guard header > hsize else { throw ZstdError.corrupt("huffman weights") }
            var bits = try BackBits(src + 1 + hsize, header - hsize)
            var s1 = bits.read(log)
            var s2 = bits.read(log)
            let mask = (1 << log) - 1
            while true {
                guard nWeights < 255 else { throw ZstdError.corrupt("too many huffman weights") }
                var e = weightTable[s1 & mask]
                weights[nWeights] = UInt8(e >> 24)
                nWeights += 1
                bits.reload()
                s1 = Int(e & 0xFFFF) + bits.read(Int((e >> 16) & 0xFF))
                if bits.overflowed {
                    weights[nWeights] = UInt8(weightTable[s2 & mask] >> 24)
                    nWeights += 1
                    break
                }
                guard nWeights < 255 else { throw ZstdError.corrupt("too many huffman weights") }
                e = weightTable[s2 & mask]
                weights[nWeights] = UInt8(e >> 24)
                nWeights += 1
                bits.reload()
                s2 = Int(e & 0xFFFF) + bits.read(Int((e >> 16) & 0xFF))
                if bits.overflowed {
                    weights[nWeights] = UInt8(weightTable[s1 & mask] >> 24)
                    nWeights += 1
                    break
                }
            }
            used = 1 + header
        }
        // Derive the last weight from the power-of-two total.
        var total = 0
        for i in 0..<nWeights {
            guard weights[i] <= 11 else { throw ZstdError.corrupt("huffman weight") }
            if weights[i] > 0 { total += 1 << (Int(weights[i]) - 1) }
        }
        guard total > 0 else { throw ZstdError.corrupt("huffman weights sum") }
        let maxBits = (Int.bitWidth - 1 - total.leadingZeroBitCount) + 1
        guard maxBits <= 11 else { throw ZstdError.corrupt("huffman depth") }
        let leftover = (1 << maxBits) - total
        guard leftover > 0, leftover & (leftover - 1) == 0 else { throw ZstdError.corrupt("huffman weights") }
        guard nWeights < 256 else { throw ZstdError.corrupt("huffman symbols") }
        weights[nWeights] = UInt8((Int.bitWidth - 1 - leftover.leadingZeroBitCount) + 1)
        let nSymbols = nWeights + 1

        // Build the decoding table: symbols with the most bits fill the lowest indices.
        var rankCount = [Int](repeating: 0, count: 13)
        var bitsFor = [Int](repeating: 0, count: nSymbols)
        for s in 0..<nSymbols where weights[s] > 0 {
            bitsFor[s] = maxBits + 1 - Int(weights[s])
            rankCount[bitsFor[s]] += 1
        }
        var rankIdx = [Int](repeating: 0, count: 13)
        rankIdx[maxBits] = 0
        var i = maxBits
        while i >= 1 {
            rankIdx[i - 1] = rankIdx[i] + rankCount[i] * (1 << (maxBits - i))
            i -= 1
        }
        guard rankIdx[0] == 1 << maxBits else { throw ZstdError.corrupt("huffman table size") }
        for s in 0..<nSymbols where bitsFor[s] > 0 {
            let nb = bitsFor[s]
            let code = rankIdx[nb]
            let len = 1 << (maxBits - nb)
            let entry = UInt16(s) << 8 | UInt16(nb)
            (huffTable + code).initialize(repeating: entry, count: len)
            rankIdx[nb] += len
        }
        huffBits = maxBits
        haveHuff = true
        return used
    }

    private func decodeHuffman1(_ src: UnsafePointer<UInt8>, _ size: Int, _ dst: UnsafeMutablePointer<UInt8>, _ count: Int) throws {
        var bits = try BackBits(src, size)
        let table = huffTable
        let n = huffBits
        var i = 0
        // Four symbols per reload: 4 × 11 bits fit after any reload.
        while i + 4 <= count {
            bits.reload()
            var e = table[Int(bits.peek(n))]; dst[i] = UInt8(e >> 8); bits.skip(Int(e & 0xFF))
            e = table[Int(bits.peek(n))]; dst[i + 1] = UInt8(e >> 8); bits.skip(Int(e & 0xFF))
            e = table[Int(bits.peek(n))]; dst[i + 2] = UInt8(e >> 8); bits.skip(Int(e & 0xFF))
            e = table[Int(bits.peek(n))]; dst[i + 3] = UInt8(e >> 8); bits.skip(Int(e & 0xFF))
            i += 4
        }
        bits.reload()
        while i < count {
            let e = table[Int(bits.peek(n))]
            dst[i] = UInt8(e >> 8)
            bits.skip(Int(e & 0xFF))
            i += 1
        }
        guard bits.finished else { throw ZstdError.corrupt("huffman stream length") }
    }

    private func decodeHuffman4(_ src: UnsafePointer<UInt8>, _ size: Int, _ count: Int) throws {
        guard size >= 10 else { throw ZstdError.truncated }
        let s1 = Int(src[0]) | Int(src[1]) << 8
        let s2 = Int(src[2]) | Int(src[3]) << 8
        let s3 = Int(src[4]) | Int(src[5]) << 8
        let s4 = size - 6 - s1 - s2 - s3
        guard s4 > 0 else { throw ZstdError.corrupt("huffman jump table") }
        let seg = (count + 3) / 4
        guard count >= 3 * seg else { throw ZstdError.corrupt("huffman segment size") }
        var q = src + 6
        try decodeHuffman1(q, s1, literals, seg); q += s1
        try decodeHuffman1(q, s2, literals + seg, seg); q += s2
        try decodeHuffman1(q, s3, literals + 2 * seg, seg); q += s3
        try decodeHuffman1(q, s4, literals + 3 * seg, count - 3 * seg)
    }

    // MARK: FSE

    /// Reads an FSE normalized-count header and builds the decoding table. Returns the accuracy log.
    private func readFSEHeader(_ fb: inout ForwardBits, maxLog: Int, maxSymbol: Int, into table: UnsafeMutablePointer<UInt32>) throws -> Int {
        let log = try fb.read(4) + 5
        guard log <= maxLog else { throw ZstdError.corrupt("FSE accuracy log") }
        var remaining = 1 << log
        var norm = [Int16](repeating: 0, count: maxSymbol + 1)
        var symbol = 0
        while remaining > 0 && symbol <= maxSymbol {
            let bits = (Int.bitWidth - 1 - (remaining + 1).leadingZeroBitCount) + 1
            var val = try fb.read(bits)
            let lowerMask = (1 << (bits - 1)) - 1
            let threshold = (1 << bits) - 1 - (remaining + 1)
            if (val & lowerMask) < threshold {
                fb.rewind(1)
                val &= lowerMask
            } else if val > lowerMask {
                val -= threshold
            }
            let proba = val - 1
            remaining -= proba < 0 ? -proba : proba
            norm[symbol] = Int16(proba)
            symbol += 1
            if proba == 0 {
                var repeatCount = try fb.read(2)
                while true {
                    var k = 0
                    while k < repeatCount && symbol <= maxSymbol {
                        norm[symbol] = 0
                        symbol += 1
                        k += 1
                    }
                    if repeatCount == 3 { repeatCount = try fb.read(2) } else { break }
                }
            }
        }
        guard remaining == 0 else { throw ZstdError.corrupt("FSE distribution") }
        try buildFSETable(norm, symbol, log, table)
        return log
    }

    func buildFSETable(_ norm: [Int16], _ nSymbols: Int, _ log: Int, _ table: UnsafeMutablePointer<UInt32>) throws {
        let size = 1 << log
        var symbols = [UInt8](repeating: 0, count: size)
        var next = [Int](repeating: 0, count: max(nSymbols, 1))
        var high = size
        for s in 0..<nSymbols where norm[s] == -1 {
            high -= 1
            guard high >= 0 else { throw ZstdError.corrupt("FSE table") }
            symbols[high] = UInt8(s)
            next[s] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var pos = 0
        for s in 0..<nSymbols where norm[s] > 0 {
            next[s] = Int(norm[s])
            for _ in 0..<Int(norm[s]) {
                symbols[pos] = UInt8(s)
                repeat { pos = (pos + step) & mask } while pos >= high
            }
        }
        guard pos == 0 else { throw ZstdError.corrupt("FSE spread") }
        for i in 0..<size {
            let s = Int(symbols[i])
            let desc = next[s]
            next[s] += 1
            guard desc > 0 else { throw ZstdError.corrupt("FSE state") }
            let nb = log - (Int.bitWidth - 1 - desc.leadingZeroBitCount)
            let base = (desc << nb) - size
            table[i] = UInt32(s) << 24 | UInt32(nb) << 16 | UInt32(truncatingIfNeeded: base)
        }
    }

    private func setRLE(_ table: UnsafeMutablePointer<UInt32>, symbol: UInt8) {
        table[0] = UInt32(symbol) << 24
    }

    // MARK: Sequences

    private func decodeSequences(
        _ src: UnsafePointer<UInt8>, _ size: Int,
        _ lit: UnsafePointer<UInt8>, _ litCount: Int,
        _ out: ZstdOutput, frameStart: Int
    ) throws {
        guard size >= 1 else { throw ZstdError.truncated }
        var p = 0
        let b0 = Int(src[0])
        var nSeq = 0
        if b0 == 0 {
            out.ensure(litCount)
            (out.base + out.count).update(from: lit, count: litCount)
            out.count += litCount
            guard size == 1 else { throw ZstdError.corrupt("data after empty sequences") }
            return
        } else if b0 < 128 {
            nSeq = b0
            p = 1
        } else if b0 < 255 {
            guard size >= 2 else { throw ZstdError.truncated }
            nSeq = ((b0 - 128) << 8) + Int(src[1])
            p = 2
        } else {
            guard size >= 3 else { throw ZstdError.truncated }
            nSeq = Int(src[1]) + (Int(src[2]) << 8) + 0x7F00
            p = 3
        }
        guard size > p else { throw ZstdError.truncated }
        let modes = Int(src[p])
        p += 1
        guard modes & 3 == 0 else { throw ZstdError.corrupt("reserved sequence mode bits") }
        try readTable(mode: (modes >> 6) & 3, src, &p, size, table: llTable, log: &llLog, have: &haveLL,
                      maxLog: 9, maxSymbol: 35, predefined: ZstdTables.llDefault, predefinedLog: 6)
        try readTable(mode: (modes >> 4) & 3, src, &p, size, table: ofTable, log: &ofLog, have: &haveOF,
                      maxLog: 8, maxSymbol: 31, predefined: ZstdTables.ofDefault, predefinedLog: 5)
        try readTable(mode: (modes >> 2) & 3, src, &p, size, table: mlTable, log: &mlLog, have: &haveML,
                      maxLog: 9, maxSymbol: 52, predefined: ZstdTables.mlDefault, predefinedLog: 6)

        guard size > p else { throw ZstdError.truncated }
        var bits = try BackBits(src + p, size - p)
        var llState = bits.read(llLog)
        var ofState = bits.read(ofLog)
        var mlState = bits.read(mlLog)
        bits.reload()

        let llT = llTable, ofT = ofTable, mlT = mlTable
        let llMask = (1 << llLog) - 1, ofMask = (1 << ofLog) - 1, mlMask = (1 << mlLog) - 1
        var litPos = 0
        var (r0, r1, r2) = rep

        // Ensure room for the remaining literals plus every match up front, re-checking as we go.
        out.ensure(litCount + ZstdDecoder.maxBlock)

        for seq in 0..<nSeq {
            let lle = llT[llState & llMask]
            let ofe = ofT[ofState & ofMask]
            let mle = mlT[mlState & mlMask]
            let ofCode = Int(ofe >> 24)
            let llCode = Int(lle >> 24)
            let mlCode = Int(mle >> 24)
            guard ofCode <= 31, llCode <= 35, mlCode <= 52 else { throw ZstdError.corrupt("sequence code") }

            var offsetValue = 1 << ofCode
            if ofCode > 0 { offsetValue += bits.read(ofCode) }
            if ofCode > 25 { bits.reload() }
            let mlBits = Int(ZstdTables.mlBits[mlCode])
            var ml = Int(ZstdTables.mlBase[mlCode])
            if mlBits > 0 { ml += bits.read(mlBits) }
            let llBits = Int(ZstdTables.llBits[llCode])
            var ll = Int(ZstdTables.llBase[llCode])
            if llBits > 0 { ll += bits.read(llBits) }
            bits.reload()

            // Resolve the offset, updating the repeat-offset history.
            var offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                r2 = r1; r1 = r0; r0 = offset
            } else {
                let idx = ll == 0 ? offsetValue + 1 : offsetValue
                switch idx {
                case 1:
                    offset = r0
                case 2:
                    offset = r1
                    r1 = r0; r0 = offset
                case 3:
                    offset = r2
                    r2 = r1; r1 = r0; r0 = offset
                default:
                    offset = r0 - 1
                    if offset == 0 { offset = 1 }
                    r2 = r1; r1 = r0; r0 = offset
                }
            }

            if seq + 1 < nSeq {
                llState = Int(lle & 0xFFFF) + bits.read(Int((lle >> 16) & 0xFF))
                mlState = Int(mle & 0xFFFF) + bits.read(Int((mle >> 16) & 0xFF))
                ofState = Int(ofe & 0xFFFF) + bits.read(Int((ofe >> 16) & 0xFF))
                bits.reload()
            }

            guard ll <= litCount - litPos else { throw ZstdError.corrupt("literal length") }
            out.ensure(ll + ml)
            var dst = out.base + out.count
            if ll > 0 {
                dst.update(from: lit + litPos, count: ll)
                litPos += ll
                dst += ll
            }
            let produced = out.count + ll - frameStart
            guard offset >= 1, offset <= produced else { throw ZstdError.corrupt("match offset") }
            var from = UnsafePointer(dst - offset)
            if offset >= 16 {
                // Non-overlapping 16-byte chunks; the output keeps slack past its capacity.
                var left = ml
                while left > 0 {
                    UnsafeMutableRawPointer(dst).storeBytes(
                        of: UnsafeRawPointer(from).loadUnaligned(as: (UInt64, UInt64).self),
                        as: (UInt64, UInt64).self)
                    dst += 16; from += 16; left -= 16
                }
            } else if offset >= 8 {
                var left = ml
                while left > 0 {
                    UnsafeMutableRawPointer(dst).storeBytes(of: UnsafeRawPointer(from).loadUnaligned(as: UInt64.self), as: UInt64.self)
                    dst += 8; from += 8; left -= 8
                }
            } else {
                for k in 0..<ml { dst[k] = from[k] }
            }
            out.count += ll + ml
        }
        guard bits.finished else { throw ZstdError.corrupt("sequence bitstream length") }
        rep = (r0, r1, r2)
        let rest = litCount - litPos
        if rest > 0 {
            out.ensure(rest)
            (out.base + out.count).update(from: lit + litPos, count: rest)
            out.count += rest
        }
    }

    private func readTable(
        mode: Int, _ src: UnsafePointer<UInt8>, _ p: inout Int, _ size: Int,
        table: UnsafeMutablePointer<UInt32>, log: inout Int, have: inout Bool,
        maxLog: Int, maxSymbol: Int, predefined: [Int16], predefinedLog: Int
    ) throws {
        switch mode {
        case 0:
            try buildFSETable(predefined, predefined.count, predefinedLog, table)
            log = predefinedLog
        case 1:
            guard p < size else { throw ZstdError.truncated }
            guard Int(src[p]) <= maxSymbol else { throw ZstdError.corrupt("RLE symbol") }
            setRLE(table, symbol: src[p])
            log = 0
            p += 1
        case 2:
            var fb = ForwardBits(src + p, size - p)
            log = try readFSEHeader(&fb, maxLog: maxLog, maxSymbol: maxSymbol, into: table)
            p += fb.bytesUsed
        default:
            guard have else { throw ZstdError.corrupt("repeat table without a previous table") }
        }
        have = true
    }
}

// MARK: - Tables

enum ZstdTables {
    static let llDefault: [Int16] = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    static let mlDefault: [Int16] = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ]
    static let ofDefault: [Int16] = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]
    static let llBase: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536,
    ]
    static let llBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]
    static let mlBase: [UInt32] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539,
    ]
    static let mlBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]
}

// MARK: - XXH64

enum XXH64 {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x &<< r) | (x &>> (64 - r)) }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    static func hash(_ ptr: UnsafePointer<UInt8>, _ len: Int, seed: UInt64 = 0) -> UInt64 {
        let raw = UnsafeRawPointer(ptr)
        var i = 0
        var h: UInt64
        if len >= 32 {
            var v1 = seed &+ p1 &+ p2, v2 = seed &+ p2, v3 = seed, v4 = seed &- p1
            while i + 32 <= len {
                v1 = round(v1, raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                v2 = round(v2, raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self))
                v3 = round(v3, raw.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self))
                v4 = round(v4, raw.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self))
                i += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1); h = merge(h, v2); h = merge(h, v3); h = merge(h, v4)
        } else {
            h = seed &+ p5
        }
        h = h &+ UInt64(len)
        while i + 8 <= len {
            h ^= round(0, raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))
            h = rotl(h, 27) &* p1 &+ p4
            i += 8
        }
        if i + 4 <= len {
            h ^= UInt64(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            i += 4
        }
        while i < len {
            h ^= UInt64(ptr[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }
}
