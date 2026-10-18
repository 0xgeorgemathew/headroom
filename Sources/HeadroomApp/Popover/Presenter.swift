import AppKit
import HeadroomKit

/// Everything the Pace card needs for one provider, gathered from live state or a fixture.
struct PaceInput {
    var provider: Provider
    var reading: LimitReading?
    /// Glide history per window id.
    var samples: [String: [UsageSample]] = [:]
    var fault: Fault? = nil
    /// Tracker-smoothed state, when available (live app). Fixtures use the raw analysis.
    var smoothedState: PacingState? = nil
    var weekCostMicros: Int64? = nil
    var planMonthlyOverride: Double? = nil
    /// Start of the current window when it reset early (an early reset happened this week).
    var earlyResetAt: Date? = nil
}

/// Turns Kit analyses into card models: the single place UI copy is assembled.
@MainActor
struct Presenter {
    var now: Date
    var calendar: Calendar = Display.calendar
    var locale: Locale = Display.locale
    var policy: PacingPolicy = .standard

    func paceCard(_ input: PaceInput) -> PaceCardModel {
        let p = input.provider
        guard let reading = input.reading else {
            return PaceCardModel(
                provider: p, plan: nil,
                freshness: Freshness(text: input.fault == nil ? "…" : "—", status: input.fault == nil ? .stale : .error,
                                     tooltip: input.fault?.message(for: p, lastGood: nil)),
                session: nil, hero: nil, meter: nil, glide: nil, verdict: nil, callout: nil, rows: [],
                fault: input.fault.map { FaultBannerModel(message: $0.message(for: p, lastGood: nil), detail: retryDetail($0)) }
                    ?? FaultBannerModel(message: "Waiting for the first \(p.displayName) reading…", detail: nil)
            )
        }

        let age = now.timeIntervalSince(reading.fetchedAt)
        let lastGoodClock = TimeFormat.clock(reading.fetchedAt, calendar: calendar, locale: locale)
        let freshness = Freshness(
            text: TimeFormat.freshness(since: reading.fetchedAt, now: now),
            status: input.fault != nil ? .error : (age <= 300 ? .fresh : .stale),
            tooltip: input.fault.map { $0.message(for: p, lastGood: lastGoodClock) } ?? "Updated \(lastGoodClock) · \(sourceLabel(reading.source))"
        )

        let session = SessionStatus(window: reading.session, now: now, policy: policy)
        var model = PaceCardModel(provider: p, plan: reading.plan?.pill, freshness: freshness, session: nil, hero: nil,
                                  meter: nil, glide: nil, verdict: nil, callout: nil, rows: [], fault: nil)

        if let s = session, s.showsBanner, let resetsAt = s.resetsAt {
            let clock = TimeFormat.clock(resetsAt, calendar: calendar, locale: locale)
            model.session = SessionBannerModel(
                level: s.level, used: s.used, title: s.title,
                subtitle: s.level == .blocked ? "back at \(clock)" : "\(percent(s.remaining)) left · resets \(clock)",
                countdown: TimeFormat.compact(s.countdown ?? 0), caption: "to reset"
            )
        }

        let blocked = session?.level == .blocked
        if let headline = reading.headline, headline.resetsAt != nil {
            let samples = input.samples[headline.id] ?? []
            let a = PacingEngine.analyze(window: headline, samples: samples, now: now, policy: policy)
            let state = input.smoothedState ?? a.state
            let period = a.isMonthly ? "month" : "week"
            let label = headline.kind == .modelWeekly ? "left this \(period) · \(headline.label ?? "model")" : "left this \(period)"
            model.hero = HeroModel(
                percentLeft: Int((a.remaining * 100).rounded()), label: label,
                renewValue: TimeFormat.compact(a.timeLeft),
                renewCaption: TimeFormat.renewalCaption(a.resetsAt, now: now, calendar: calendar, locale: locale),
                hourglass: a.hourglass
            )
            let opacity: Double = input.fault != nil ? 0.5 : (blocked || a.rule == .exhausted ? 0.4 : 1)
            model.meter = MeterModel(state: state, cells: a.cells, caret: a.rule == .exhausted ? nil : a.evenPaceMarker, opacity: opacity)
            model.glide = glide(a, samples: samples, state: state)
            let v = VerdictWriter.verdict(for: a, window: headline, now: now, calendar: calendar, locale: locale, state: state)
            model.verdict = VerdictModel(state: v.state, title: v.title, multiple: v.multipleText, primary: v.primary, secondary: v.secondary)
            model.callout = callout(reading, headline: headline, earlyResetAt: input.earlyResetAt)
        }

        // Detail rows.
        if let s = session, !s.showsBanner, let w = reading.session {
            model.rows.append(DetailRowModel(
                icon: .ring(used: s.used, level: s.level), label: "5-hour session",
                value: "\(percent(s.remaining)) left",
                suffix: w.resetsAt.map { TimeFormat.clock($0, calendar: calendar, locale: locale) }
            ))
        }
        if let row = creditsRow(reading) { model.rows.append(row) }
        if let micros = input.weekCostMicros {
            let multiple = PlanComparison.multiple(weeklyCostMicros: micros, plan: reading.plan, monthlyOverrideUSD: input.planMonthlyOverride)
            model.rows.append(DetailRowModel(
                icon: .coin(p), label: "This \(model.hero?.label.contains("month") == true ? "month" : "week") at API rates",
                value: NumberFormat.dollars(micros: micros, style: .compact),
                suffix: multiple.map { NumberFormat.multiple($0, suffix: "plan") }
            ))
        }

        if let f = input.fault {
            model.fault = FaultBannerModel(message: f.message(for: p, lastGood: lastGoodClock), detail: retryDetail(f, age: age))
        }
        return model
    }

    // MARK: Pieces

    private func glide(_ a: PacingAnalysis, samples: [UsageSample], state: PacingState) -> GlideModel {
        let hours = a.duration / 3600
        let nowT = a.elapsed * hours
        var points = samples
            .filter { $0.time >= a.windowStart && $0.time <= now }
            .map { GlideModel.Point(t: $0.time.timeIntervalSince(a.windowStart) / 3600, used: $0.used) }
        if points.first.map({ $0.t > 0.5 }) ?? true { points.insert(GlideModel.Point(t: 0, used: 0), at: 0) }
        points.append(GlideModel.Point(t: nowT, used: 1 - a.remaining))
        var end = (t: nowT, remaining: a.remaining)
        var runsOut = false
        var label: String? = nil
        if a.rule == .exhausted {
            end = (nowT, 0)
        } else if let runOut = a.projectedRunOut, runOut < a.resetsAt {
            end = (runOut.timeIntervalSince(a.windowStart) / 3600, 0)
            runsOut = true
        } else if let unused = a.projectedUnusedAtReset {
            end = (hours, unused)
            if unused >= 0.005 { label = "\(percent(unused)) renews unused" }
        } else {
            // No burn history yet: project at even pace.
            end = (hours, max(0, a.remaining - a.timeFraction))
        }
        return GlideModel(hours: hours, windowStart: a.windowStart, nowT: nowT, points: points, projectionEnd: end,
                          runsOut: runsOut, endLabel: label, state: state)
    }

    private func callout(_ r: LimitReading, headline: LimitWindow, earlyResetAt: Date?) -> CalloutModel? {
        let caps = r.modelCaps.filter { $0.id != headline.id }
        if let empty = caps.first(where: { $0.used >= 1 }) {
            let when = empty.resetsAt.map { " · resets " + TimeFormat.shortDayTime($0, now: now, calendar: calendar, locale: locale) } ?? ""
            return CalloutModel(kind: .capEmpty, text: "\(empty.label ?? "Model") weekly cap reached\(when) · other models still available")
        }
        let tight = caps.compactMap { cap -> (LimitWindow, PacingAnalysis)? in
            guard cap.resetsAt != nil, cap.remaining < headline.remaining else { return nil }
            let a = PacingEngine.analyze(window: cap, samples: [], now: now, policy: policy)
            return a.state >= .tight ? (cap, a) : nil
        }.min { $0.0.remaining < $1.0.remaining }
        if let (cap, a) = tight {
            return CalloutModel(kind: .capTight, text: "\(cap.label ?? "Model") cap \(percent(cap.remaining)) left · \(a.state.word == "tight" ? "getting tight" : a.state.word)")
        }
        if let early = earlyResetAt, let resetsAt = headline.resetsAt {
            let day = TimeFormat.weekdayShort(early, calendar: calendar, locale: locale)
            let next = TimeFormat.dayAndClock(resetsAt, now: now, calendar: calendar, locale: locale)
            return CalloutModel(kind: .earlyReset, text: "Reset early on \(day) · new week to \(next)")
        }
        return nil
    }

    private func creditsRow(_ r: LimitReading) -> DetailRowModel? {
        let total = r.totalResetCredits
        guard total > 0 else { return nil }
        let sorted = r.resetCredits.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let horizon = policy.creditExpiryHighlight
        let soon = sorted.filter { $0.expiresAt.map { $0.timeIntervalSince(now) <= horizon && $0 > now } ?? false }
        let tooltip = sorted.map { c in
            let name = c.title ?? "Reset credit"
            let count = c.count > 1 ? " ×\(c.count)" : ""
            let exp = c.expiresAt.map { "expires " + TimeFormat.dayAndClock($0, now: now, calendar: calendar, locale: locale) } ?? "no expiry"
            return "\(name)\(count) · \(exp)"
        }.joined(separator: "\n")
        if let first = soon.first, let exp = first.expiresAt {
            let n = soon.reduce(0) { $0 + $1.count }
            return DetailRowModel(icon: .hourglass(highlight: true), label: "Reset credits",
                                  value: "\(n) lapses in \(TimeFormat.compact(exp.timeIntervalSince(now)))",
                                  suffix: "\(total) total", highlight: true, tooltip: tooltip.isEmpty ? nil : tooltip)
        }
        return DetailRowModel(icon: .hourglass(highlight: false), label: "Reset credits", value: "\(total) available",
                              suffix: nil, tooltip: tooltip.isEmpty ? nil : tooltip)
    }

    private func retryDetail(_ f: Fault, age: TimeInterval? = nil) -> String? {
        let ageText = age.map { " · reading is \(TimeFormat.compact($0)) old" } ?? ""
        switch f {
        case .enterprise, .apiKeyLogin: return nil
        default: return "Retrying automatically" + ageText
        }
    }

    private func sourceLabel(_ s: ReadingSource) -> String {
        switch s {
        case .api: "usage API"
        case .appServer: "Codex app-server"
        case .passiveLog: "Codex session log"
        case .cliText: "claude /usage"
        }
    }

    func percent(_ f: Double) -> String { "\(Int((max(0, f) * 100).rounded()))%" }
}
