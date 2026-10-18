import CryptoKit
import Foundation
import Testing
@testable import HeadroomCore

enum FixturePath {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    static func data(_ relative: String) throws -> Data { try Data(contentsOf: url(relative)) }
}

private struct Expected {
    let size: Int
    let sha256: String

    static func load() throws -> [String: Expected] {
        let text = try String(contentsOf: FixturePath.url("zstd/expected.txt"), encoding: .utf8)
        var out: [String: Expected] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let size = Int(parts[1]) else { continue }
            out[String(parts[0])] = Expected(size: size, sha256: String(parts[2]))
        }
        return out
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("Zstd decoder")
struct ZstdTests {
    @Test(arguments: [
        ("text.l1.zst", "text.jsonl"),
        ("text.l19.zst", "text.jsonl"),
        ("text.l22long.zst", "text.jsonl"),
        ("random.zst", "random.bin"),
        ("runs.zst", "runs.bin"),
        ("multi.zst", "multi.expected"),
    ])
    func decodesVector(_ compressed: String, _ original: String) throws {
        let expected = try #require(try Expected.load()[original])
        let out = try Zstd.decompress(try FixturePath.data("zstd/" + compressed))
        #expect(out.count == expected.size)
        #expect(sha256(out) == expected.sha256)
    }

    @Test func decodesTinyFrame() throws {
        let out = try Zstd.decompress(try FixturePath.data("zstd/tiny.zst"))
        #expect(out == (try FixturePath.data("zstd/tiny.txt")))
    }

    @Test func recognizesMagic() throws {
        #expect(Zstd.isZstd(try FixturePath.data("zstd/tiny.zst")))
        #expect(!Zstd.isZstd(Data("{\"a\":1}\n".utf8)))
    }

    @Test func skipsSkippableFrames() throws {
        var data = Data([0x50, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 9, 9, 9])
        data.append(try FixturePath.data("zstd/tiny.zst"))
        #expect(try Zstd.decompress(data) == (try FixturePath.data("zstd/tiny.txt")))
    }

    @Test func rejectsNonZstd() {
        #expect(throws: ZstdError.notZstd) { try Zstd.decompress(Data("hello world".utf8)) }
    }

    @Test func detectsChecksumMismatch() throws {
        var data = try FixturePath.data("zstd/text.l1.zst")
        data[data.count - 1] ^= 0xFF
        #expect(throws: ZstdError.checksumMismatch) { try Zstd.decompress(data) }
    }

    @Test func truncatedInputThrows() throws {
        let data = try FixturePath.data("zstd/text.l19.zst")
        for cut in [5, 12, 100, data.count / 2, data.count - 5] {
            #expect(throws: (any Error).self) { try Zstd.decompress(data.prefix(cut)) }
        }
    }

    @Test func corruptBytesNeverTrap() throws {
        let original = try FixturePath.data("zstd/text.l19.zst")
        var rng = SystemRandomNumberGenerator()
        var threw = 0
        for _ in 0..<300 {
            var data = original
            for _ in 0..<4 {
                let i = Int.random(in: 6..<data.count, using: &rng)
                data[i] = UInt8.random(in: 0...255, using: &rng)
            }
            do { _ = try Zstd.decompress(data) } catch { threw += 1 }
        }
        // Checksums catch whatever the structural checks let through.
        #expect(threw == 300)
    }

    @Test func xxh64KnownValues() {
        // Reference values from the xxHash specification test vectors.
        let empty = [UInt8]()
        #expect(empty.withUnsafeBufferPointer { XXH64.hash($0.baseAddress ?? UnsafePointer(bitPattern: 1)!, 0) } == 0xEF46_DB37_51D8_E999)
        let abc = Array("abc".utf8)
        #expect(abc.withUnsafeBufferPointer { XXH64.hash($0.baseAddress!, 3) } == 0x44BC_2CF5_AD77_0999)
    }
}
