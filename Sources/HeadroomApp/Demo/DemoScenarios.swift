import AppKit
import HeadroomCore
import HeadroomKit

/// Fixture-driven states for every surface, so the visual pass can reach each one without
/// waiting for real usage (`HeadroomApp --demo <name>` or `--render <name>`).
@MainActor
enum Demo {
    /// Tuesday 2026-10-20 10:00 local — the mockup's moment.
    static var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 20; c.hour = 10; c.minute = 0
        return Display.calendar.date(from: c)!
    }

    static func at(_ base: Date, hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    /// Port of the mockup's `series()`: cumulative used fraction sampled hourly, with daytime
    /// activity and a deterministic jitter.
    static func series(total: Double, nowH: Int, startHour: Int, seed: Int, shape: ((Int) -> Double)? = nil) -> [Double] {
        var s = seed
        func rnd() -> Double { s = (s * 16807) % 2147483647; return Double(s) / 2147483647 }
        var w: [Double] = []
        for h in 0..<nowH {
            let lh = (startHour + h) % 24
            var v = lh >= 10 && lh <= 19 ? 1 : lh >= 20 && lh <= 23 ? 0.35 : 0.03
            v *= shape?(h) ?? 1
            w.append(v * (0.55 + rnd() * 0.9))
        }
        let sum = w.reduce(0, +)
        var c = [0.0]
        for v in w { c.append(c[c.count - 1] + v / sum * total) }
        return c
    }

    static func samples(_ cum: [Double], start: Date) -> [UsageSample] {
        cum.enumerated().map { UsageSample(time: at(start, hours: Double($0.offset)), used: $0.element) }
    }

    // MARK: Pace inputs

    struct PaceScenario {
        var name: String
        var inputs: [PaceInput]
        var note: String
    }

    static func claudeMockup(now: Date) -> PaceInput {
        let start = at(now, hours: -148)
        let cum = series(total: 0.18, nowH: 148, startHour: 6, seed: 11)
        let weekly = LimitWindow(id: "weekly", kind: .weekly, used: 0.18, resetsAt: at(start, hours: 168), duration: 168 * 3600)
        let session = LimitWindow(id: "session", kind: .session, used: 0.84, resetsAt: at(now, hours: 0.8), duration: 5 * 3600)
        let reading = LimitReading(provider: .claude, fetchedAt: at(now, hours: -2.0 / 60), source: .api,
                                   plan: PlanCatalog.claude(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"),
                                   windows: [session, weekly])
        // Flatten the last day so the projection lands at "80% renews unused".
        var s = samples(cum, start: start)
        for i in s.indices where s[i].time > at(now, hours: -24) { s[i].used = min(s[i].used, 0.18 - 0.001 * now.timeIntervalSince(s[i].time) / 3600) }
        // A heavy last half hour: the session runs out a little before its reset.
        let sStart = at(now, hours: -4.2)
        let sess = [0.0, 0.12, 0.30, 0.46, 0.58, 0.66, 0.70].enumerated().map { UsageSample(time: at(sStart, hours: Double($0.offset) * 0.6), used: $0.element) }
            + [UsageSample(time: now, used: 0.84)]
        return PaceInput(provider: .claude, reading: reading, samples: ["weekly": s, "session": sess], weekCostMicros: 412_000_000)
    }

    static func codexMockup(now: Date) -> PaceInput {
        let start = at(now, hours: -69)
        let cum = series(total: 0.41, nowH: 69, startHour: 13, seed: 5) { $0 > 45 ? 2.4 : 1 }
        let weekly = LimitWindow(id: "weekly", kind: .weekly, used: 0.41, resetsAt: at(start, hours: 168), duration: 168 * 3600)
        let session = LimitWindow(id: "session", kind: .session, used: 0.10, resetsAt: at(now, hours: 4.2), duration: 5 * 3600)
        let credits = [
            ResetCredit(expiresAt: at(now, hours: 72), title: "Weekly limit reset"),
            ResetCredit(expiresAt: at(now, hours: 24 * 20), title: "Weekly limit reset"),
            ResetCredit(expiresAt: nil, title: nil),
        ]
        let reading = LimitReading(provider: .codex, fetchedAt: at(now, hours: -2.0 / 60), source: .appServer,
                                   plan: PlanCatalog.codex(planType: "pro"), windows: [session, weekly],
                                   resetCredits: credits, resetCreditsAvailable: 3)
        return PaceInput(provider: .codex, reading: reading, samples: ["weekly": samples(cum, start: start)], weekCostMicros: 186_000_000)
    }

    /// A single-window state for the state gallery: used `u` with `elapsedH` of 168 gone,
    /// and a burn over the last day.
    static func state(_ p: Provider, used u: Double, elapsedH: Double, lastDayBurn: Double? = nil, session: Double = 0.3,
                      fault: Fault? = nil, caps: [LimitWindow] = [], credits: [ResetCredit] = [], now: Date) -> PaceInput {
        let start = at(now, hours: -elapsedH)
        let weekly = LimitWindow(id: "weekly", kind: .weekly, used: u, resetsAt: at(start, hours: 168), duration: 168 * 3600)
        let sess = LimitWindow(id: "session", kind: .session, used: session, resetsAt: at(now, hours: 2.2), duration: 5 * 3600)
        var s: [UsageSample] = []
        let n = Int(elapsedH)
        let dayBurn = lastDayBurn ?? (u / max(elapsedH, 1) * 24)
        let usedAtDayStart = max(0, u - dayBurn)
        for h in 0...max(n, 1) {
            let t = Double(h)
            let used: Double = t <= elapsedH - 24 ? usedAtDayStart * t / max(elapsedH - 24, 1) : usedAtDayStart + (u - usedAtDayStart) * (t - (elapsedH - 24)) / 24
            s.append(UsageSample(time: at(start, hours: t), used: min(used, u)))
        }
        let plan = p == .claude ? PlanCatalog.claude(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") : PlanCatalog.codex(planType: "plus")
        let reading = LimitReading(provider: p, fetchedAt: at(now, hours: fault == nil ? -1.0 / 60 : -1.6), source: p == .claude ? .api : .appServer,
                                   plan: plan, windows: [sess, weekly] + caps, resetCredits: credits)
        return PaceInput(provider: p, reading: reading, samples: ["weekly": s], fault: fault, weekCostMicros: p == .claude ? 96_400_000 : 31_200_000)
    }

    static func paceScenarios(now: Date) -> [PaceScenario] {
        var out: [PaceScenario] = [
            PaceScenario(name: "mockup", inputs: [claudeMockup(now: now), codexMockup(now: now)], note: "Pace mockup: amber session, Plenty; Codex tight by projection"),
            PaceScenario(name: "plenty", inputs: [state(.claude, used: 0.18, elapsedH: 150, now: now)], note: "Plenty available + hourglass"),
            PaceScenario(name: "onpace", inputs: [state(.codex, used: 0.40, elapsedH: 84, now: now)], note: "On pace"),
            PaceScenario(name: "tight", inputs: [state(.claude, used: 0.62, elapsedH: 88, now: now)], note: "Getting tight (S rule)"),
            PaceScenario(name: "tight-projection", inputs: [codexMockup(now: now)], note: "Getting tight (projection)"),
            PaceScenario(name: "verytight", inputs: [state(.codex, used: 0.82, elapsedH: 72, now: now)], note: "Very tight"),
            PaceScenario(name: "exhausted", inputs: [state(.claude, used: 1, elapsedH: 140, now: now)], note: "Weekly limit reached"),
        ]
        for (level, used) in [("session-row", 0.42), ("session-runsout", 0.6), ("session-amber", 0.84), ("session-rose", 0.94), ("session-blocked", 1.0)] {
            out.append(PaceScenario(name: level, inputs: [state(.claude, used: 0.46, elapsedH: 90, session: used, now: now)], note: "5-hour session \(level)"))
        }
        let faults: [(String, Fault)] = [
            ("fault-offline", .offline), ("fault-signedout", .signedOut), ("fault-cli", .cliMissing),
            ("fault-enterprise", .enterprise), ("fault-outage", .outage(description: "Claude Code partial outage (status.claude.com).")),
            ("fault-schema", .schemaDrift),
        ]
        for (name, f) in faults {
            out.append(PaceScenario(name: name, inputs: [state(.claude, used: 0.46, elapsedH: 90, fault: f, now: now)], note: name))
        }
        out.append(PaceScenario(name: "fault-codex-signedout", inputs: [PaceInput(provider: .codex, reading: nil, fault: .signedOut)], note: "No reading yet"))
        let fable = LimitWindow(id: LimitWindow.modelID("Fable"), kind: .modelWeekly, label: "Fable", used: 1, resetsAt: at(now, hours: 72), duration: 168 * 3600)
        out.append(PaceScenario(name: "cap-empty", inputs: [state(.claude, used: 0.40, elapsedH: 96, caps: [fable], now: now)], note: "Model cap reached"))
        var fableTight = fable; fableTight.used = 0.62
        out.append(PaceScenario(name: "cap-tight", inputs: [state(.claude, used: 0.30, elapsedH: 80, caps: [fableTight], now: now)], note: "Model cap tighter than weekly"))
        var early = state(.codex, used: 0.12, elapsedH: 30, now: now)
        early.earlyResetAt = at(now, hours: -30)
        out.append(PaceScenario(name: "early-reset", inputs: [early], note: "Early reset"))
        let credits = [ResetCredit(expiresAt: at(now, hours: 50), title: "Weekly limit reset", count: 1), ResetCredit(expiresAt: at(now, hours: 400), title: "Weekly limit reset", count: 1)]
        out.append(PaceScenario(name: "credits", inputs: [state(.codex, used: 0.35, elapsedH: 70, credits: credits, now: now)], note: "Reset credits expiring"))
        // Free plan: one 30-day window (PLAN §14.2).
        let mStart = at(now, hours: -9 * 24)
        let monthly = LimitWindow(id: "weekly", kind: .weekly, used: 0.22, resetsAt: at(mStart, hours: 30 * 24), duration: 30 * 86400)
        let mSamples = (0...(9 * 24)).map { UsageSample(time: at(mStart, hours: Double($0)), used: 0.22 * Double($0) / (9 * 24)) }
        out.append(PaceScenario(name: "monthly", inputs: [PaceInput(provider: .codex, reading: LimitReading(provider: .codex, fetchedAt: now, source: .appServer, plan: PlanCatalog.codex(planType: "free"), windows: [monthly]), samples: ["weekly": mSamples])], note: "Free plan, 30-day window"))
        // Team seat without an all-models weekly limit: the Fable cap is the headline.
        let fableHead = LimitWindow(id: LimitWindow.modelID("Fable"), kind: .modelWeekly, label: "Fable", used: 0.35, resetsAt: at(now, hours: 60), duration: 168 * 3600, isActive: true)
        let teamSession = LimitWindow(id: "session", kind: .session, used: 0.5, resetsAt: at(now, hours: 2))
        out.append(PaceScenario(name: "team-scoped", inputs: [PaceInput(provider: .claude, reading: LimitReading(provider: .claude, fetchedAt: now, source: .api, plan: PlanCatalog.claude(subscriptionType: "team", rateLimitTier: "default_claude_max_5x"), windows: [teamSession, fableHead]))], note: "No weekly_all: scoped cap headline"))
        return out
    }
}

extension Demo {
    /// About a week of 5-hour sessions, newest last; the last one still running.
    static func sessionHistory(_ p: Provider, now: Date) -> [SessionRecord] {
        let claude: [(dayAgo: Int, hour: Double, peak: Double, hitAfterH: Double?)] = [
            (6, 9, 0.62, nil), (6, 14.5, 0.88, nil), (5, 9.5, 1, 3.6), (5, 15, 0.71, nil), (4, 10, 0.45, nil), (4, 15.5, 0.93, nil),
            (3, 9, 1, 4.1), (3, 14.5, 0.58, nil), (2, 10, 0.34, nil), (2, 16, 0.79, nil), (1, 9, 0.66, nil), (1, 14.5, 1, 3.2),
            (1, 20, 0.28, nil), (0, 5.8, 0.84, nil),
        ]
        let codex: [(dayAgo: Int, hour: Double, peak: Double, hitAfterH: Double?)] = [
            (6, 13, 0.22, nil), (5, 11, 0.41, nil), (5, 17, 0.18, nil), (4, 10, 0.36, nil), (3, 12, 0.52, nil), (3, 18, 0.30, nil),
            (2, 9.5, 0.47, nil), (2, 15, 0.81, nil), (1, 11, 0.26, nil), (1, 17, 0.39, nil), (0, 5.8, 0.10, nil),
        ]
        let cal = Display.calendar
        let today = cal.startOfDay(for: now)
        return (p == .claude ? claude : codex).enumerated().map { i, s in
            let start = cal.date(byAdding: .day, value: -s.dayAgo, to: today)!.addingTimeInterval(s.hour * 3600)
            let last = i == (p == .claude ? claude : codex).count - 1
            return SessionRecord(start: start, resetsAt: start.addingTimeInterval(5 * 3600), peakUsed: s.peak,
                                 hitLimitAt: s.hitAfterH.map { start.addingTimeInterval($0 * 3600) }, inProgress: last)
        }
    }
}
