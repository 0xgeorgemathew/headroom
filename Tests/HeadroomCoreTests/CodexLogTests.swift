import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

func parseCodex(_ lines: [String], state: inout CodexFileState, file: String = "/f") -> [CodexLine] {
    lines.map { line in
        let bytes = Array(line.utf8)
        return bytes.withUnsafeBufferPointer { CodexLogParser.parse($0.baseAddress!, $0.count, state: &state, fileKey: file) }
    }
}

enum CodexLines {
    static func meta(provider: String = "openai", cwd: String = "/Users/user/projects/beta") -> String {
        #"{"timestamp":"2026-10-10T09:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"s","cwd":"\#(cwd)","originator":"codex_cli","cli_version":"0.163.0","model_provider":"\#(provider)"}}"#
    }

    static func turn(model: String) -> String {
        #"{"timestamp":"2026-10-10T09:00:01.000Z","ordinal":1,"type":"turn_context","payload":{"turn_id":"t","cwd":"/x","model":"\#(model)"}}"#
    }

    static func record(_ id: String, input: Int, cached: Int, write: Int = 0, output: Int, ts: String = "2026-10-10T09:01:00.000Z") -> String {
        #"{"timestamp":"\#(ts)","ordinal":2,"type":"token_usage_record","payload":{"thread_id":"th","turn_id":"t","response_id":"\#(id)","usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(write),"output_tokens":\#(output),"reasoning_output_tokens":1,"total_tokens":\#(input + output)}}}"#
    }

    static func tokenCount(last: (Int, Int, Int), total: (Int, Int, Int), ts: String = "2026-10-10T09:02:00.000Z", used: Double = 12.5) -> String {
        let l = #"{"input_tokens":\#(last.0),"cached_input_tokens":\#(last.1),"output_tokens":\#(last.2),"reasoning_output_tokens":0,"total_tokens":\#(last.0 + last.2)}"#
        let t = #"{"input_tokens":\#(total.0),"cached_input_tokens":\#(total.1),"output_tokens":\#(total.2),"reasoning_output_tokens":0,"total_tokens":\#(total.0 + total.2)}"#
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(t),"last_token_usage":\#(l),"model_context_window":272000},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\#(used),"window_minutes":300,"resets_at":1792504200},"secondary":{"used_percent":41.0,"window_minutes":10080,"resets_at":1792846800},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"pro","rate_limit_reached_type":null}}}"#
    }
}

private func events(_ lines: [CodexLine]) -> [UsageEvent] {
    lines.flatMap { line -> [UsageEvent] in
        switch line {
        case .event(let e), .eventRetracting(let e, _): return [e]
        case .legacy(let e, _): return e.map { [$0] } ?? []
        default: return []
        }
    }
}

@Suite("Codex log parser")
struct CodexLogTests {
    @Test func recordsUseLatestTurnModelAndSubsetSemantics() throws {
        var state = CodexFileState()
        let out = parseCodex([
            CodexLines.meta(), CodexLines.turn(model: "gpt-6.1-sol"),
            CodexLines.record("r1", input: 1000, cached: 700, write: 100, output: 50),
            CodexLines.turn(model: "gpt-6-luna"),
            CodexLines.record("r2", input: 10, cached: 0, output: 5),
        ], state: &state)
        let e = events(out)
        #expect(e.count == 2)
        #expect(e[0].model == "gpt-6.1-sol" && e[1].model == "gpt-6-luna")
        #expect(e[0].project == "beta")
        #expect(e[0].tokens == TokenCounts(newInput: 200, cacheWrite5m: 100, cacheRead: 700, output: 50))
        #expect(e[0].dedupeKey == "R:r1")
        #expect(state.provider == "openai")
    }

    @Test func recordsSuppressTokenCountUsageButKeepLimits() throws {
        var state = CodexFileState()
        let out = parseCodex([
            CodexLines.meta(), CodexLines.turn(model: "m"),
            CodexLines.record("r1", input: 10, cached: 0, output: 5),
            CodexLines.tokenCount(last: (10, 0, 5), total: (10, 0, 5)),
        ], state: &state)
        #expect(events(out).count == 1)
        guard case .limits(let l) = out[3] else { Issue.record("expected limits"); return }
        #expect(l.providerIsOpenAI)
        #expect(l.primary?.usedPercent == 12.5 && l.primary?.windowMinutes == 300)
        #expect(l.secondary?.resetsAt == Date(timeIntervalSince1970: 1_792_846_800))
        #expect(l.planType == "pro")
        #expect(l.hasCredits == false)
    }

    @Test func legacyFilesUseLastUsageAndSkipUnchangedTotals() {
        var state = CodexFileState()
        let out = parseCodex([
            CodexLines.meta(provider: "codex-lb"), CodexLines.turn(model: "m"),
            CodexLines.tokenCount(last: (100, 60, 10), total: (100, 60, 10)),
            CodexLines.tokenCount(last: (100, 60, 10), total: (100, 60, 10)), // unchanged: rate-limit update only
            CodexLines.tokenCount(last: (50, 0, 5), total: (150, 60, 15)),
        ], state: &state)
        let e = events(out)
        #expect(e.count == 2)
        #expect(e[0].tokens == TokenCounts(newInput: 40, cacheRead: 60, output: 10))
        #expect(e[0].dedupeKey == "L:/f#1")
        // Custom-provider limits are surfaced but marked untrusted.
        guard case .legacy(_, let l?) = out[2] else { Issue.record("expected limits"); return }
        #expect(!l.providerIsOpenAI)
    }

    @Test func firstRecordRetractsEarlierLegacyEvents() {
        var state = CodexFileState()
        let out = parseCodex([
            CodexLines.meta(), CodexLines.turn(model: "m"),
            CodexLines.tokenCount(last: (10, 0, 1), total: (10, 0, 1)),
            CodexLines.record("r1", input: 10, cached: 0, output: 1),
        ], state: &state)
        guard case .eventRetracting(_, let keys) = out[3] else { Issue.record("expected retraction"); return }
        #expect(keys == ["L:/f#1"])
        #expect(state.sawRecord && state.legacyKeys.isEmpty)
    }

    @Test func fixtureRollout() throws {
        let text = try String(contentsOf: FixturePath.url("logs/codex-rollout-new.jsonl"), encoding: .utf8)
        var state = CodexFileState()
        let out = parseCodex(text.split(separator: "\n").map(String.init), state: &state)
        let e = events(out)
        #expect(e.count == 40)
        #expect(Set(e.map(\.model)) == ["gpt-6-astra"])
        #expect(e.reduce(TokenCounts.zero) { $0 + $1.tokens } == TokenCounts(newInput: 333_216, cacheRead: 3_483_520, output: 28_633))
        let limits = out.compactMap { line -> PassiveCodexLimits? in
            if case .limits(let l) = line { return l }
            return nil
        }
        #expect(!limits.isEmpty && limits.allSatisfy(\.providerIsOpenAI))
        #expect(limits.last?.planType == "self_serve_business_prolite")
    }
}
