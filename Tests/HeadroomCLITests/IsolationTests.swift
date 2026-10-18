import Foundation
import Testing

/// PLAN §10: the CLI cannot leak credentials because it doesn't link the credential or network
/// code. Checked with `nm` on the built binary.
@Suite struct IsolationTests {
    static var binary: URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for config in ["debug", "release"] {
            let url = repo.appendingPathComponent(".build/\(config)/headroom")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func symbols(_ flags: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        p.arguments = flags + [try #require(Self.binary).path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(.enabled(if: binary != nil, "build the headroom product first"))
    func cliLinksNoNetworkOrCredentialCode() throws {
        let undefined = try symbols(["-u"])
        for forbidden in ["URLSession", "NWPathMonitor", "nw_path", "SecItem", "SecKeychain", "_CFNetwork", "NSTask", "posix_spawn"] {
            #expect(!undefined.contains(forbidden), "headroom imports \(forbidden)")
        }
        let defined = try symbols(["-g", "-defined-only"])
        for forbidden in ["ClaudeUsageClient", "ClaudeCredential", "CodexAppServerClient", "StatusClient", "LogIngestor"] {
            #expect(!defined.contains(forbidden), "headroom contains \(forbidden)")
        }
    }
}
