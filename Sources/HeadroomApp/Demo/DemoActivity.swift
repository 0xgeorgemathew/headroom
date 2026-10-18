import Foundation
import HeadroomKit

@MainActor
extension Demo {
    /// Activity "now": Tuesday 9:30 so 24 hourly bars start at 10 AM, like the mockup.
    static var activityNow: Date { now.addingTimeInterval(-30 * 60) }

    /// Hourly aggregates reproducing the mockup's bars (millions of tokens per hour) and model mix.
    static func activityAggregates(now: Date, pricing: PricingEngine) -> [HourAggregate] {
        let cv: [Double] = [30, 17, 9, 18, 55, 69.4, 48, 16.6, 4, 8, 24, 15, 8, 1, 0, 0, 0, 0, 0, 0, 0, 1, 9, 20]
        let xv: [Double] = [52, 32, 18, 22, 92, 96, 52, 17, 2, 7, 56, 58, 32, 2, 0, 0, 0, 0, 0, 0, 1, 0, 36, 84]
        let cal = Calendar.current
        let current = cal.dateInterval(of: .hour, for: now)!.start
        var out: [HourAggregate] = []
        func add(_ p: Provider, _ values: [Double], models: [(String, Double)], projects: [String], daysBack: Int) {
            for day in 0...daysBack {
                for (i, v) in values.enumerated() where v > 0 {
                    let hour = current.addingTimeInterval(Double(i - 23) * 3600 - Double(day) * 86400)
                    let scale = day == 0 ? 1 : 0.35 + 0.5 * Double((day * 7 + i) % 5) / 4
                    for (j, (model, share)) in models.enumerated() {
                        let total = v * 1_000_000 * share * scale
                        let tokens = TokenCounts(newInput: Int64(total * 0.026), cacheWrite5m: 0, cacheWrite1h: Int64(total * 0.004),
                                                 cacheRead: Int64(total * 0.964), output: Int64(total * 0.006))
                        let cost = pricing.price(tokens: tokens, model: model)
                        out.append(HourAggregate(provider: p, hour: hour, model: model, project: projects[(i + j) % projects.count],
                                                 tokens: tokens, micros: cost.micros, priced: cost.priced,
                                                 classMicros: ClassMicros(input: cost.input, cacheWrite: cost.cacheWrite, cacheRead: cost.cacheRead, output: cost.output)))
                    }
                }
            }
        }
        add(.claude, cv, models: [("claude-opus-5-5", 0.55), ("claude-fable-5", 0.08), ("claude-haiku-5-5", 0.37)], projects: ["agent-kit", "web-app", "infra"], daysBack: 29)
        add(.codex, xv, models: [("gpt-6.1-sol", 0.78), ("gpt-6-astra", 0.07), ("glm-5.3-flash", 0.15)], projects: ["web-app", "data-pipeline"], daysBack: 29)
        return out
    }

    static func pastWeeks(collecting: Bool = false) -> [PastWeeksModel] {
        if collecting {
            return [PastWeeksModel(provider: .claude, weeks: [], planChange: nil, chips: [], collecting: true),
                    PastWeeksModel(provider: .codex, weeks: [], planChange: nil, chips: [], collecting: true)]
        }
        func cols(_ specs: [(Double, Int, Int, Int?)], projected: Double) -> [WeekColumn] {
            specs.enumerated().map { i, s in
                WeekColumn(used: s.0, projected: i == specs.count - 1 ? projected : nil, ranOutHoursEarly: s.3, sessionHits: s.1,
                           earlyResets: s.2, isCurrent: i == specs.count - 1, caption: "Week \(i + 1) · \(Int(s.0 * 100))% used")
            }
        }
        let claude = cols([(0.58, 0, 0, nil), (0.71, 1, 0, nil), (0.41, 0, 0, nil), (1, 2, 0, 31), (0.62, 0, 0, nil), (0.76, 1, 0, nil), (0.49, 0, 0, nil), (0.18, 0, 0, nil)], projected: 0.30)
        let codex = cols([(0.52, 0, 0, nil), (0.64, 0, 0, nil), (0.88, 1, 1, nil), (0.38, 0, 0, nil), (0.55, 0, 1, nil), (1, 2, 0, 19), (0.47, 0, 1, nil), (0.41, 0, 0, nil)], projected: 0.96)
        return [
            PastWeeksModel(provider: .claude, weeks: claude, planChange: nil, chips: [(.rose, "ran out 1 of 8"), (.azure, "36% unused avg")], collecting: false),
            PastWeeksModel(provider: .codex, weeks: codex, planChange: (after: 1, pill: "PRO"), chips: [(.rose, "ran out 1 of 6"), (.spark, "3 early resets")], collecting: false),
        ]
    }
}
