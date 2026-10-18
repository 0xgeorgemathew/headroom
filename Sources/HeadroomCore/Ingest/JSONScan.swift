import Foundation

/// A byte span inside a buffer.
struct ByteSpan: Equatable {
    var start: Int
    var end: Int
    var count: Int { end - start }
}

/// Allocation-free JSON walker over one log line. It visits object keys and skips values it
/// doesn't need, so multi-MB tool-output lines are never decoded (PLAN §4.2). Malformed input
/// returns nil rather than trapping.
struct JSONScan {
    let p: UnsafePointer<UInt8>
    let count: Int

    init(_ p: UnsafePointer<UInt8>, _ count: Int) {
        self.p = p
        self.count = count
    }

    @inline(__always) func skipSpace(_ i: Int) -> Int {
        var i = i
        while i < count {
            let c = p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
        return i
    }

    /// Index just past the closing quote of the string starting at `i` (which must be `"`).
    func skipString(_ i: Int) -> Int? {
        guard i < count, p[i] == 0x22 else { return nil }
        var j = i + 1
        while j < count {
            guard let q = memchr(p + j, 0x22, count - j) else { return nil }
            let at = UnsafePointer<UInt8>(q.assumingMemoryBound(to: UInt8.self)) - p
            var backslashes = 0
            var k = at - 1
            while k > i && p[k] == 0x5C {
                backslashes += 1
                k -= 1
            }
            if backslashes % 2 == 0 { return at + 1 }
            j = at + 1
        }
        return nil
    }

    /// Index just past the value starting at (or after whitespace from) `i`.
    func skipValue(_ i: Int) -> Int? {
        let i = skipSpace(i)
        guard i < count else { return nil }
        switch p[i] {
        case 0x22:
            return skipString(i)
        case 0x7B, 0x5B:
            var depth = 0
            var j = i
            while j < count {
                let c = p[j]
                switch c {
                case 0x22:
                    guard let e = skipString(j) else { return nil }
                    j = e
                    continue
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return j + 1 }
                default:
                    break
                }
                j += 1
            }
            return nil
        default:
            var j = i
            while j < count {
                let c = p[j]
                if c == 0x2C || c == 0x7D || c == 0x5D || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { break }
                j += 1
            }
            return j > i ? j : nil
        }
    }

    /// Calls `body(keySpan, valueSpan)` for each member of the object starting at `i`.
    /// The key span excludes quotes. Returning false stops early. Returns false on malformed input.
    @discardableResult
    func forEachMember(_ i: Int, _ body: (ByteSpan, ByteSpan) -> Bool) -> Bool {
        var i = skipSpace(i)
        guard i < count, p[i] == 0x7B else { return false }
        i = skipSpace(i + 1)
        if i < count, p[i] == 0x7D { return true }
        while i < count {
            guard p[i] == 0x22, let keyEnd = skipString(i) else { return false }
            let key = ByteSpan(start: i + 1, end: keyEnd - 1)
            var j = skipSpace(keyEnd)
            guard j < count, p[j] == 0x3A else { return false }
            j = skipSpace(j + 1)
            guard let valueEnd = skipValue(j) else { return false }
            if !body(key, ByteSpan(start: j, end: valueEnd)) { return true }
            j = skipSpace(valueEnd)
            guard j < count else { return false }
            if p[j] == 0x7D { return true }
            guard p[j] == 0x2C else { return false }
            i = skipSpace(j + 1)
        }
        return false
    }

    /// True when the key span equals `name` (ASCII, no escapes).
    @inline(__always) func key(_ span: ByteSpan, is name: StaticString) -> Bool {
        let n = name.utf8CodeUnitCount
        guard span.count == n else { return false }
        return memcmp(p + span.start, name.utf8Start, n) == 0
    }

    /// Decodes a string value. Escaped strings fall back to JSONSerialization (rare for the fields we read).
    func string(_ span: ByteSpan) -> String? {
        guard span.count >= 2, p[span.start] == 0x22, p[span.end - 1] == 0x22 else { return nil }
        let inner = UnsafeBufferPointer(start: p + span.start + 1, count: span.count - 2)
        if memchr(inner.baseAddress!, 0x5C, inner.count) == nil {
            return String(decoding: inner, as: UTF8.self)
        }
        let data = Data(UnsafeBufferPointer(start: p + span.start, count: span.count))
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    /// Raw bytes of a string value without quotes, when it has no escapes. Avoids a String allocation.
    func rawString(_ span: ByteSpan) -> UnsafeBufferPointer<UInt8>? {
        guard span.count >= 2, p[span.start] == 0x22, p[span.end - 1] == 0x22 else { return nil }
        return UnsafeBufferPointer(start: p + span.start + 1, count: span.count - 2)
    }

    /// Integer value (JSON numbers like `12`, `-3`, `12.0`). Null and non-numbers return nil.
    func int(_ span: ByteSpan) -> Int64? {
        var i = span.start
        guard i < span.end else { return nil }
        var negative = false
        if p[i] == 0x2D { negative = true; i += 1 }
        var v: Int64 = 0
        var digits = 0
        while i < span.end, p[i] >= 0x30, p[i] <= 0x39 {
            v = v &* 10 &+ Int64(p[i] - 0x30)
            i += 1
            digits += 1
        }
        guard digits > 0 else { return nil }
        if i < span.end, p[i] == 0x2E || p[i] == 0x65 || p[i] == 0x45 {
            // Fractional or exponent form: parse as Double.
            let s = String(decoding: UnsafeBufferPointer(start: p + span.start, count: span.count), as: UTF8.self)
            return Double(s).map { Int64($0) }
        }
        return negative ? -v : v
    }

    func double(_ span: ByteSpan) -> Double? {
        guard span.count > 0, p[span.start] != 0x6E else { return nil }
        let s = String(decoding: UnsafeBufferPointer(start: p + span.start, count: span.count), as: UTF8.self)
        return Double(s)
    }

    func bool(_ span: ByteSpan) -> Bool? {
        guard span.count >= 4 else { return nil }
        if p[span.start] == 0x74 { return true }
        if p[span.start] == 0x66 { return false }
        return nil
    }

    func isNull(_ span: ByteSpan) -> Bool { span.count == 4 && p[span.start] == 0x6E }
}

/// Fast parser for the ISO-8601 timestamps in Claude and Codex logs
/// (`2026-10-17T10:00:00.000Z`, `2026-10-18T04:39:59.548985+00:00`). Returns seconds since 1970.
enum FastTimestamp {
    static func parse(_ b: UnsafeBufferPointer<UInt8>) -> Double? {
        guard b.count >= 19 else { return nil }
        @inline(__always) func d(_ i: Int) -> Int? {
            let c = b[i]
            return c >= 0x30 && c <= 0x39 ? Int(c - 0x30) : nil
        }
        guard let y0 = d(0), let y1 = d(1), let y2 = d(2), let y3 = d(3),
              let mo0 = d(5), let mo1 = d(6), let d0 = d(8), let d1 = d(9),
              let h0 = d(11), let h1 = d(12), let mi0 = d(14), let mi1 = d(15),
              let s0 = d(17), let s1 = d(18) else { return nil }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = mo0 * 10 + mo1
        let day = d0 * 10 + d1
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        let hour = h0 * 10 + h1, minute = mi0 * 10 + mi1, second = s0 * 10 + s1
        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < b.count, let v = d(i) {
                fraction += Double(v) * scale
                scale *= 0.1
                i += 1
            }
        }
        var offset = 0
        if i < b.count {
            let c = b[i]
            if c == 0x2B || c == 0x2D, i + 2 < b.count, let oh0 = d(i + 1), let oh1 = d(i + 2) {
                var om = 0
                if i + 5 < b.count, b[i + 3] == 0x3A, let m0 = d(i + 4), let m1 = d(i + 5) {
                    om = m0 * 10 + m1
                } else if i + 4 < b.count, let m0 = d(i + 3), let m1 = d(i + 4) {
                    om = m0 * 10 + m1
                }
                offset = ((oh0 * 10 + oh1) * 60 + om) * 60 * (c == 0x2D ? -1 : 1)
            }
        }
        let days = daysFromCivil(year, month, day)
        let secs = days * 86400 + hour * 3600 + minute * 60 + second - offset
        return Double(secs) + fraction
    }

    /// Howard Hinnant's days-from-civil.
    static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
