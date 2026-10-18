import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

func parseClaude(_ line: String, fallback: String = "@test:0") -> UsageEvent? {
    let bytes = Array(line.utf8)
    return bytes.withUnsafeBufferPointer { ClaudeLogParser.parse($0.baseAddress!, $0.count, fallbackKey: fallback) }
}

func parseClaudeFixture(_ name: String) throws -> [UsageEvent] {
    let text = try String(contentsOf: FixturePath.url("logs/" + name), encoding: .utf8)
    return text.split(separator: "\n").compactMap { parseClaude(String($0)) }
}

/// A minimal Claude Code assistant line with the real key order.
func claudeLine(id: String = "msg_1", request: String = "req_1", model: String = "claude-opus-5-5",
                ts: String = "2026-10-17T10:00:00.000Z", input: Int = 2, write: Int = 100, read: Int = 1000,
                output: Int = 50, speed: String = "standard", cwd: String = "/Users/user/projects/alpha",
                content: String = #"[{"type":"text","text":"[redacted]"}]"#) -> String {
    #"{"parentUuid":"u0","isSidechain":false,"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":\#(content),"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"output_tokens":\#(output),"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":\#(write),"ephemeral_5m_input_tokens":0},"speed":"\#(speed)"}},"requestId":"\#(request)","type":"assistant","uuid":"u1","timestamp":"\#(ts)","cwd":"\#(cwd)","sessionId":"s1"}"#
}

@Suite("Claude log parser")
struct ClaudeLogTests {
    @Test func parsesAssistantLine() throws {
        let e = try #require(parseClaude(claudeLine()))
        #expect(e.provider == .claude)
        #expect(e.model == "claude-opus-5-5")
        #expect(e.project == "alpha")
        #expect(e.dedupeKey == "msg_1:req_1")
        #expect(e.tokens == TokenCounts(newInput: 2, cacheWrite5m: 0, cacheWrite1h: 100, cacheRead: 1000, output: 50))
        #expect(e.speed == .standard)
        #expect(e.timestamp == Date(timeIntervalSince1970: 1_792_231_200))
    }

    @Test func fastModeAndSplitFallback() throws {
        let fast = try #require(parseClaude(claudeLine(speed: "fast")))
        #expect(fast.speed == .fast)
        // No cache_creation split: all creation tokens count as 5-minute writes.
        let line = #"{"message":{"model":"claude-haiku-5-5","id":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":40,"cache_read_input_tokens":0,"output_tokens":3}},"requestId":"r","type":"assistant","timestamp":"2026-10-17T10:00:00Z"}"#
        let e = try #require(parseClaude(line))
        #expect(e.tokens.cacheWrite5m == 40 && e.tokens.cacheWrite1h == 0)
    }

    @Test func ignoresUserLinesThatMentionUsage() {
        let user = #"{"type":"user","message":{"role":"user","content":"{\"usage\":{\"input_tokens\":5}} and \"type\":\"assistant\""},"timestamp":"2026-10-17T10:00:00Z"}"#
        #expect(parseClaude(user) == nil)
        // Literal (unescaped) pattern inside a tool result object still isn't an assistant line.
        let toolResult = #"{"type":"user","toolUseResult":{"usage":{"input_tokens":5},"type":"assistant"},"timestamp":"2026-10-17T10:00:00Z"}"#
        #expect(parseClaude(toolResult) == nil)
    }

    @Test func toolInputsDoNotOverrideMessageFields() throws {
        let content = #"[{"type":"tool_use","id":"t","name":"Task","input":{"model":"haiku","id":"fake","usage":{"input_tokens":999}}}]"#
        let e = try #require(parseClaude(claudeLine(content: content)))
        #expect(e.model == "claude-opus-5-5")
        #expect(e.dedupeKey == "msg_1:req_1")
        #expect(e.tokens.newInput == 2)
    }

    @Test func skipsZeroTokenSyntheticEvents() {
        let line = claudeLine(model: "<synthetic>", input: 0, write: 0, read: 0, output: 0)
        #expect(parseClaude(line) == nil)
    }

    @Test func keylessLineUsesFallback() throws {
        let line = #"{"message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}},"type":"assistant","timestamp":"2026-10-17T10:00:00Z"}"#
        #expect(try #require(parseClaude(line, fallback: "@f:12")).dedupeKey == "@f:12")
    }

    @Test func fixturesParse() throws {
        let main = try parseClaudeFixture("claude-main.jsonl")
        let sub = try parseClaudeFixture("claude-subagent.jsonl")
        let special = try parseClaudeFixture("claude-special.jsonl")
        #expect(main.count == 4)
        #expect(sub.count == 4)
        #expect(Set(special.map(\.model)) == ["glm-5.3", "glm-5.3-flash", "claude-opus-5-5"])
        #expect(special.contains { $0.speed == .fast })
        #expect((main + sub + special).allSatisfy { $0.project == "project-a" || $0.project == "project-b" })
    }
}
