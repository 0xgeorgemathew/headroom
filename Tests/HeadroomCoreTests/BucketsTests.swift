import Foundation
import HeadroomKit
import Testing
@testable import HeadroomCore

private func event(_ model: String, _ project: String?, at t: TimeInterval, out: Int64, key: String, provider: Provider = .claude) -> UsageEvent {
    UsageEvent(provider: provider, timestamp: Date(timeIntervalSince1970: t), model: model, project: project,
               tokens: TokenCounts(newInput: 1, cacheRead: 10, output: out), dedupeKey: key)
}

@Suite("Usage buckets")
struct BucketsTests {
    let base: TimeInterval = 1_792_224_000 // 2026-10-17T08:00:00Z

    func ledger() -> UsageLedger {
        var l = UsageLedger()
        let p = flatPricer
        for (i, e) in [
            event("opus", "alpha", at: base + 60, out: 100, key: "1"),
            event("opus", "beta", at: base + 3600 + 5, out: 200, key: "2"),
            event("haiku", "alpha", at: base + 7200 + 5, out: 50, key: "3"),
            event("glm-5.3", "alpha", at: base + 7200 + 9, out: 7, key: "4"),
            event("gpt-6-astra", "gamma", at: base + 10, out: 1, key: "5", provider: .codex),
        ].enumerated() {
            l.add(e, file: "/f\(i % 2)", price: p(e))
        }
        return l
    }

    @Test func totalsAndRanges() {
        let b = ledger().buckets
        let all = b.totals(.claude, from: .distantPast, to: .distantFuture)
        #expect(all.events == 4)
        #expect(all.tokens.output == 357)
        #expect(all.unpricedTokens == 1 + 10 + 7)
        #expect(all.cost.output == 350)
        let firstHour = b.totals(.claude, from: Date(timeIntervalSince1970: base), to: Date(timeIntervalSince1970: base + 3600))
        #expect(firstHour.tokens.output == 100)
        #expect(b.totals(nil, from: .distantPast, to: .distantFuture).events == 5)
    }

    @Test func seriesBinsByEdges() {
        let b = ledger().buckets
        let edges = (0...3).map { Date(timeIntervalSince1970: base + Double($0) * 3600) }
        let s = b.series(.claude, edges: edges)
        #expect(s.map(\.tokens.output) == [100, 200, 57])
    }

    @Test func breakdownByModelAndProject() {
        let b = ledger().buckets
        let models = b.breakdown(.claude, by: .model, from: .distantPast, to: .distantFuture)
        #expect(models.map(\.name) == ["opus", "haiku", "glm-5.3"])
        let projects = b.breakdown(.claude, by: .project, from: .distantPast, to: .distantFuture)
        #expect(projects.first?.name == "beta")
        #expect(b.unpricedModels(.claude, from: .distantPast, to: .distantFuture).map(\.name) == ["glm-5.3"])
        #expect(b.lastActivity(.codex) == Date(timeIntervalSince1970: base))
    }

    @Test func retractPruneAndReprice() {
        var l = ledger()
        l.retract(keys: ["2"])
        #expect(l.buckets.totals(.claude, from: .distantPast, to: .distantFuture).tokens.output == 157)
        l.prune(before: Date(timeIntervalSince1970: base + 7200))
        #expect(l.buckets.totals(.claude, from: .distantPast, to: .distantFuture).events == 2)
        l.reprice { _ in EventPrice(cost: ClassCost(output: 1), priced: true) }
        let t = l.buckets.totals(.claude, from: .distantPast, to: .distantFuture)
        #expect(t.micros == 2 && t.unpricedTokens == 0)
    }

    @Test func binLayouts() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let now = Date(timeIntervalSince1970: base + 1234)
        let hours = UsageBuckets.hourEdges(endingAt: now, calendar: cal)
        #expect(hours.count == 25)
        #expect(hours.last! > now && hours[hours.count - 2] <= now)
        // Local hours in a +05:30 zone fall on :30 UTC, which quarter-hour slots represent exactly.
        #expect(Int(hours[0].timeIntervalSince1970) % 900 == 0)
        let four = UsageBuckets.fourHourEdges(endingAt: now, calendar: cal)
        #expect(four.count == 43)
        #expect(cal.component(.hour, from: four[0]) % 4 == 0)
        let days = UsageBuckets.dayEdges(endingAt: now, calendar: cal)
        #expect(days.count == 31)
        #expect(cal.component(.hour, from: days[0]) == 0)
    }
}
