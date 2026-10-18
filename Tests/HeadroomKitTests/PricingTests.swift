import Foundation
import Testing
@testable import HeadroomKit

/// Fixed mix used by the golden tests. Prompt = 100,000 tokens: exactly at, not above, the Haiku 5.5 tier.
private let mix = TokenCounts(newInput: 10_000, cacheWrite5m: 20_000, cacheWrite1h: 30_000, cacheRead: 40_000, output: 5_000)

private func engine() throws -> PricingEngine {
    PricingEngine(table: try PriceTable.bundled())
}

private func event(_ model: String, _ tokens: TokenCounts = mix, speed: Speed = .standard, provider: Provider = .claude) -> UsageEvent {
    UsageEvent(provider: provider, timestamp: Date(timeIntervalSince1970: 0), model: model, tokens: tokens, speed: speed)
}

@Suite("Pricing table")
struct PriceTableTests {
    @Test func bundledTableLoads() throws {
        let table = try PriceTable.bundled()
        #expect(table.asOf == "2026-10-18")
        #expect(table.models.count == 17)
        #expect(table.aliases["opus"] == "claude-opus-5-5")
    }

    @Test func overrideAddsAndReplacesModels() throws {
        let override = try PriceTable.decode(Data("""
        {"models": {"GLM-5.3-Flash": {"input": 0.6, "output": 2.2},
                    "claude-opus-5-5": {"input": 1, "cache_write_5m": 1, "cache_write_1h": 1, "cache_read": 1, "output": 1}},
         "aliases": {"glm": "glm-5.3-flash"}}
        """.utf8))
        let merged = try PriceTable.bundled().merging(override)
        #expect(merged.asOf == "2026-10-18")
        let glm = try #require(merged.rates(for: "glm-5.3-flash"))
        #expect(glm.cacheRead == 0.6)
        #expect(glm.cacheWrite5m == 0.6)
        #expect(merged.rates(for: "glm")?.output == 2.2)
        #expect(merged.rates(for: "claude-opus-5-5")?.output == 1)
        #expect(merged.rates(for: "claude-sonnet-5-5")?.output == 10)
    }

    @Test func malformedOverrideIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pricing-bad-\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let table = PriceTable.load(overrideURL: url)
        #expect(table == (try PriceTable.bundled()))
    }

    @Test func missingOverrideIsIgnored() throws {
        let table = PriceTable.load(overrideURL: URL(fileURLWithPath: "/nonexistent/pricing.override.json"))
        #expect(table.models.count == 17)
    }

    @Test func overrideFileIsMerged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pricing-ok-\(UUID().uuidString).json")
        try Data(#"{"as_of": "2026-11-01", "models": {"glm-5.3": {"input": 0.5, "output": 2}}}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let table = PriceTable.load(overrideURL: url)
        #expect(table.asOf == "2026-11-01")
        #expect(table.rates(for: "glm-5.3") != nil)
        #expect(table.rates(for: "claude-opus-5-5") != nil)
    }
}

@Suite("Model ID normalization")
struct ModelIDTests {
    @Test(arguments: [
        ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
        ("claude-opus-5-5[1m]", "claude-opus-5-5"),
        ("Claude-Sonnet-5-5", "claude-sonnet-5-5"),
        ("anthropic/claude-sonnet-5-5", "claude-sonnet-5-5"),
        ("gpt-6.1-sol-2026-04-01", "gpt-6.1-sol"),
        ("opus", "claude-opus-5-5"),
        ("sonnet", "claude-sonnet-5-5"),
        ("haiku", "claude-haiku-5-5"),
        ("fable", "claude-fable-5-1"),
        ("claude-opus-5-5", "claude-opus-5-5"),
        ("claude-opus-4-6", "claude-opus-4-6"),
        ("gpt-6-astra", "gpt-6-astra"),
        ("glm-5.3-flash", "glm-5.3-flash"),
        ("<synthetic>", "<synthetic>"),
    ])
    func normalizes(raw: String, expected: String) {
        #expect(ModelID.normalize(raw) == expected)
    }
}

@Suite("Pricing engine golden costs")
struct PricingEngineTests {
    /// Hand-computed micro-dollars for `mix`: 10K new · 20K write 5m · 30K write 1h · 40K read · 5K out.
    @Test(arguments: [
        ("claude-fable-5-1", Int64(1_210_000)),
        ("claude-fable-5", 1_240_000),
        ("claude-opus-5-5", 488_000),
        ("claude-opus-5", 620_000),
        ("claude-sonnet-5-5", 248_000),
        ("claude-sonnet-5", 248_000),
        ("claude-haiku-5-5", 12_400),
        ("claude-opus-4-8", 620_000),
        ("claude-opus-4-7", 620_000),
        ("claude-opus-4-6", 620_000),
        ("claude-sonnet-4-6", 372_000),
        ("claude-haiku-4-5", 124_000),
        // OpenAI rows have one cache-write rate, applied to both write buckets.
        ("gpt-6-astra", 1_015_000),
        ("gpt-6.1-sol", 199_000),
        ("gpt-6-sol", 203_000),
        ("gpt-6-luna", 10_150),
        ("gpt-5.6-luna", 21_300),
    ])
    func goldenRow(model: String, expected: Int64) throws {
        let cost = try engine().price(event(model))
        #expect(cost.priced)
        #expect(cost.micros == expected)
        #expect(cost.micros == cost.input + cost.cacheWrite + cost.cacheRead + cost.output)
    }

    @Test func classBreakdownForOpus55() throws {
        let cost = try engine().price(event("claude-opus-5-5"))
        #expect(cost.input == 40_000)
        #expect(cost.cacheWrite == 100_000 + 240_000)
        #expect(cost.cacheRead == 8_000)
        #expect(cost.output == 100_000)
    }

    @Test func haikuLongContextTierAbove100K() throws {
        let tokens = TokenCounts(newInput: 50_000, cacheRead: 100_000, output: 10_000)
        let cost = try engine().price(event("claude-haiku-5-5", tokens))
        #expect(cost.micros == 25_000 + 5_000 + 25_000)
    }

    @Test func haikuTierBoundaryIsStrict() throws {
        // `mix` has a 100,000-token prompt: Standard rates.
        #expect(try engine().price(event("claude-haiku-5-5")).micros == 12_400)
        let over = TokenCounts(newInput: 10_001, cacheWrite5m: 20_000, cacheWrite1h: 30_000, cacheRead: 40_000, output: 5_000)
        // 10,001×0.5 + 20,000×0.625 + 30,000×1 + 40,000×0.05 + 5,000×2.5
        #expect(try engine().price(event("claude-haiku-5-5", over)).micros == 5_001 + 12_500 + 30_000 + 2_000 + 12_500)
    }

    @Test func openAILongContextAbove272K() throws {
        let tokens = TokenCounts(newInput: 100_000, cacheWrite5m: 100_000, cacheRead: 100_000, output: 10_000)
        let cost = try engine().price(event("gpt-6-astra", tokens, provider: .codex))
        // 2× input and cache, 1.5× output.
        #expect(cost.input == 2_000_000)
        #expect(cost.cacheWrite == 2_500_000)
        #expect(cost.cacheRead == 200_000)
        #expect(cost.output == 750_000)
        #expect(cost.micros == 5_450_000)
    }

    @Test func fastModeDoublesEveryClass() throws {
        let e = try engine()
        #expect(e.price(event("claude-opus-5-5", speed: .fast)).micros == 976_000)
        #expect(e.price(event("claude-opus-5", speed: .fast)).micros == 1_240_000)
        let fast = e.price(event("claude-opus-5-5", speed: .fast))
        #expect(fast.cacheRead == 16_000)
        #expect(fast.cacheWrite == 680_000)
    }

    @Test func speedPremiumsOnOpenAI() throws {
        let e = try engine()
        #expect(e.price(event("gpt-6-astra", speed: .ultrafast, provider: .codex)).micros == 6_090_000)
        #expect(e.price(event("gpt-6.1-sol", speed: .fast, provider: .codex)).micros == 398_000)
    }

    @Test func modelsWithoutSpeedPremiumStayStandard() throws {
        #expect(try engine().price(event("claude-sonnet-5-5", speed: .fast)).micros == 248_000)
    }

    @Test func datedAndAliasedNamesArePriced() throws {
        let e = try engine()
        #expect(e.price(event("claude-haiku-4-5-20251001")).micros == 124_000)
        #expect(e.price(event("opus")).micros == 488_000)
        #expect(e.price(event("claude-opus-5-5[1m]")).micros == 488_000)
    }

    @Test func unknownModelIsUnpriced() throws {
        let e = try engine()
        for model in ["glm-5.3-flash", "glm-5.3", "<synthetic>"] {
            let cost = e.price(event(model))
            #expect(!cost.priced)
            #expect(cost.micros == 0)
        }
    }

    @Test func costSumPropagatesUnpriced() {
        let a = Cost(input: 1, output: 2)
        #expect((a + a).micros == 6)
        #expect((a + a).priced)
        #expect(!(a + .unpriced).priced)
    }
}

@Suite("Unpriced accounting and plan comparison")
struct UnpricedAndPlanTests {
    @Test func footnoteNamesUnpricedModels() throws {
        let summary = UnpricedSummary(
            tokensByModel: ["claude-opus-5-5": 9_790, "glm-5.3-flash": 210],
            engine: try engine()
        )
        #expect(summary.models == ["glm-5.3-flash"])
        #expect(abs(summary.share - 0.021) < 1e-9)
        #expect(summary.footnote == "Rates as of 2026-10-18 · 2.1% of tokens on unpriced models (glm-5.3-flash)")
    }

    @Test func footnoteWithoutUnpricedModels() throws {
        let summary = UnpricedSummary(tokensByModel: ["claude-opus-5-5": 100], engine: try engine())
        #expect(summary.share == 0)
        #expect(summary.footnote == "Rates as of 2026-10-18")
    }

    @Test func unpricedOrderedByTokens() throws {
        let summary = UnpricedSummary(tokensByModel: ["glm-5.3": 5, "glm-5.3-flash": 50, "gpt-6-luna": 945], engine: try engine())
        #expect(summary.models == ["glm-5.3-flash", "glm-5.3"])
        #expect(summary.footnote.hasSuffix("(glm-5.3-flash, glm-5.3)"))
    }

    @Test func weeklyMultipleMatchesMockup() throws {
        let max20 = try #require(PlanCatalog.claude(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
        let claude = try #require(PlanComparison.multiple(weeklyCostMicros: 412_000_000, plan: max20))
        #expect(NumberFormat.multiple(claude, suffix: "plan") == "8.9× plan")
        let pro = try #require(PlanCatalog.codex(planType: "pro"))
        let codex = try #require(PlanComparison.multiple(weeklyCostMicros: 186_000_000, plan: pro))
        #expect(NumberFormat.multiple(codex, suffix: "plan") == "4.0× plan")
    }

    @Test func overrideReplacesListPrice() throws {
        let pro = try #require(PlanCatalog.codex(planType: "pro"))
        let x = try #require(PlanComparison.multiple(weeklyCostMicros: 120_000_000, plan: pro, monthlyOverrideUSD: 52))
        #expect(abs(x - 10) < 1e-9)
    }

    @Test func freeOrUnknownPlanHasNoMultiple() throws {
        #expect(PlanComparison.multiple(weeklyCostMicros: 1_000_000, plan: PlanCatalog.codex(planType: "free")) == nil)
        #expect(PlanComparison.multiple(weeklyCostMicros: 1_000_000, plan: nil) == nil)
        #expect(PlanComparison.multiple(weeklyCostMicros: 1_000_000, plan: PlanCatalog.codex(planType: "promax")) == nil)
    }
}
