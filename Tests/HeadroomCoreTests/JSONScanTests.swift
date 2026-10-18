import Foundation
import Testing
@testable import HeadroomCore

private func withScan<T>(_ text: String, _ body: (JSONScan) -> T) -> T {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBufferPointer { body(JSONScan($0.baseAddress!, $0.count)) }
}

@Suite("JSONScan")
struct JSONScanTests {
    @Test func visitsTopLevelKeysAndSkipsValues() {
        let line = #"{"a":"x\"y","big":{"model":"inner","list":[1,{"usage":{}}]},"model":"outer","n":-42,"f":1.5e2,"t":true,"z":null}"#
        let seen: [String] = withScan(line) { s in
            var keys: [String] = []
            s.forEachMember(0) { k, _ in
                keys.append(String(decoding: UnsafeBufferPointer(start: s.p + k.start, count: k.count), as: UTF8.self))
                return true
            }
            return keys
        }
        #expect(seen == ["a", "big", "model", "n", "f", "t", "z"])
    }

    @Test func readsValues() {
        let line = #"{"s":"plain","e":"tab\tquote\"","n":-42,"f":12.0,"t":true,"z":null}"#
        withScan(line) { s in
            var values: [String: ByteSpan] = [:]
            s.forEachMember(0) { k, v in
                values[String(decoding: UnsafeBufferPointer(start: s.p + k.start, count: k.count), as: UTF8.self)] = v
                return true
            }
            #expect(s.string(values["s"]!) == "plain")
            #expect(s.string(values["e"]!) == "tab\tquote\"")
            #expect(s.int(values["n"]!) == -42)
            #expect(s.int(values["f"]!) == 12)
            #expect(s.bool(values["t"]!) == true)
            #expect(s.isNull(values["z"]!))
            #expect(s.int(values["z"]!) == nil)
        }
    }

    @Test func escapedBackslashBeforeQuoteEndsString() {
        let line = #"{"a":"ends with backslash\\","b":1}"#
        let b: Int64? = withScan(line) { s in
            var out: Int64?
            s.forEachMember(0) { k, v in
                if s.key(k, is: "b") { out = s.int(v) }
                return true
            }
            return out
        }
        #expect(b == 1)
    }

    @Test func malformedInputReturnsFalse() {
        for bad in [#"{"a":"unterminated"#, #"{"a" 1}"#, #"["not","object"]"#, #"{"a":{"b":1}"#, ""] {
            let ok = withScan(bad.isEmpty ? " " : bad) { s in s.forEachMember(0) { _, _ in true } }
            #expect(!ok, "\(bad)")
        }
    }

    @Test func parsesTimestamps() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cases = [
            ("2026-10-17T10:00:00.000Z", "2026-10-17T10:00:00.000Z"),
            ("2026-10-18T04:39:59.548985+00:00", "2026-10-18T04:39:59.548Z"),
            ("2026-10-18T10:09:59.500+05:30", "2026-10-18T04:39:59.500Z"),
            ("2024-02-29T23:59:59Z", "2024-02-29T23:59:59.000Z"),
        ]
        for (input, expected) in cases {
            let bytes = Array(input.utf8)
            let parsed = bytes.withUnsafeBufferPointer { FastTimestamp.parse($0) }
            let want = try #require(iso.date(from: expected)).timeIntervalSince1970
            #expect(abs(try #require(parsed) - want) < 0.001, "\(input)")
        }
        let junk = Array("not a time at all!!".utf8)
        #expect(junk.withUnsafeBufferPointer { FastTimestamp.parse($0) } == nil)
    }
}
