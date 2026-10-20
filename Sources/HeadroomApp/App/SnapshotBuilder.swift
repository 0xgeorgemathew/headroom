import Foundation
import HeadroomCore
import HeadroomKit

/// Builds `snapshot.json` from the same inputs the cards use, so the CLI and the popover agree.
@MainActor
struct SnapshotBuilder {
    var now: Date
    var calendar: Calendar = Display.calendar
    var locale: Locale = Display.locale

    func build(model: AppModel) -> Snapshot {
        var presenter = model.presenter(now: now)
        presenter.calendar = calendar
        presenter.locale = locale
        let providers = model.paceInputs().map { input -> ProviderSnapshot in
            var p = provider(input, presenter: presenter, outage: model.majorOutages[input.provider])
            let day = model.buckets.totals(input.provider, from: now.addingTimeInterval(-86400), to: now)
            p.activity24h = ActivitySnapshot(tokens: day.tokens.total, newTokens: day.tokens.fresh, costUSD: day.dollars)
            return p
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return Snapshot(generatedAt: now, appVersion: version, appPID: getpid(), providers: providers)
    }

    func provider(_ input: PaceInput, presenter: Presenter, outage: String?) -> ProviderSnapshot {
        var out = ProviderSnapshot(id: input.provider)
        out.fault = input.fault.map { FaultSnapshot(code: $0.code, message: $0.message(for: input.provider, lastGood: nil)) }
        guard let r = input.reading else { return out }
        out.plan = r.plan?.pill
        out.readingAt = r.fetchedAt
        out.source = r.source.rawValue
        if let s = SessionStatus(window: r.session, now: now, policy: presenter.policy) {
            let f = SessionForecast(window: r.session, samples: input.samples[LimitWindow.sessionID()] ?? [], now: now)
            out.session = SessionSnapshot(used: s.used, left: s.remaining, resetsAt: s.resetsAt, level: SessionSnapshot.levelCode(s.level),
                                          outlook: SessionSnapshot.outlookCode(f.outlook), runsOutAt: f.runsOutAt,
                                          leftAtReset: f.leftAtReset.map { ($0 * 1000).rounded() / 1000 })
        }
        out.caps = r.modelCaps.filter { $0.id != r.headline?.id }
            .map { CapSnapshot(label: $0.label ?? "Model", used: $0.used, resetsAt: $0.resetsAt, active: $0.isActive) }
        if r.totalResetCredits > 0 {
            let horizon = now.addingTimeInterval(PacingPolicy.standard.creditExpiryHighlight)
            let dated = r.resetCredits.compactMap(\.expiresAt).filter { $0 > now }.sorted()
            let soon = r.resetCredits.filter { ($0.expiresAt.map { $0 > now && $0 <= horizon }) ?? false }.reduce(0) { $0 + $1.count }
            out.credits = CreditsSnapshot(available: r.totalResetCredits, nextExpiry: dated.first, expiringSoon: soon)
        }
        if let headline = r.headline, headline.resetsAt != nil {
            let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: now)
            let state = input.smoothedState ?? a.state
            let v = VerdictWriter.verdict(for: a, window: headline, now: now, calendar: calendar, locale: locale, state: state)
            out.weekly = WeeklySnapshot(
                label: headline.kind == .modelWeekly ? headline.label : nil,
                used: 1 - a.remaining, left: a.remaining, resetsAt: a.resetsAt, windowHours: a.duration / 3600,
                state: WeeklySnapshot.stateCode(state), multiple: a.multiple.isFinite ? (a.multiple * 100).rounded() / 100 : nil,
                cells: a.cells, hourglass: a.hourglass, runsOutAt: a.projectedRunOut.flatMap { $0 < a.resetsAt ? $0 : nil },
                unusedAtReset: a.projectedUnusedAtReset, verdict: VerdictSnapshot(title: v.title, primary: v.primary, secondary: v.secondary)
            )
            if let mb = presenter.menuBar(input, majorOutage: outage) {
                if case .blocked(let reason, let until) = UrgencyResolver.headline(mb.urgency) {
                    let (by, detail): (String, String?) = switch reason {
                    case .session: ("session", nil)
                    case .weekly: ("weekly", nil)
                    case .modelCap(let name): ("model_cap", name)
                    case .outage(let d): ("outage", d)
                    }
                    out.blocked = BlockedSnapshot(by: by, detail: detail, until: until)
                }
            }
        }
        if let micros = input.weekCostMicros {
            out.weekCostUSD = (Double(micros) / 10_000).rounded() / 100
            out.planMultiple = PlanComparison.multiple(weeklyCostMicros: micros, plan: r.plan, monthlyOverrideUSD: input.planMonthlyOverride)
                .map { ($0 * 10).rounded() / 10 }
        }
        return out
    }
}
