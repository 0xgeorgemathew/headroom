import Foundation
import HeadroomKit

extension Presenter {
    /// Menu bar model for one provider, following the binding-constraint order (PLAN §2.3).
    func menuBar(_ input: PaceInput, majorOutage: String? = nil) -> (model: MenuBarProviderModel, urgency: UrgencyInput)? {
        guard let reading = input.reading, let headline = reading.headline, headline.resetsAt != nil else {
            guard input.fault != nil else { return nil }
            let m = MenuBarProviderModel(provider: input.provider, state: .onPace, cells: 0, hourglass: false, session: nil,
                                         blockedCountdown: nil, fault: true,
                                         spoken: "\(input.provider.displayName): no reading. \(input.fault?.message(for: input.provider, lastGood: nil) ?? "")")
            let u = UrgencyInput(provider: input.provider, pacing: nil, hourglass: false, session: nil, weeklyExhausted: false,
                                 weeklyResetsAt: nil, blockedCaps: [], fault: input.fault, majorOutage: majorOutage)
            return (m, u)
        }
        let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: now, policy: policy)
        let state = input.smoothedState ?? a.state
        let session = SessionStatus(window: reading.session, now: now, policy: policy)
        let blockedCaps = reading.modelCaps.filter { $0.used >= 1 && $0.isActive && $0.id != headline.id }
            .map { UrgencyInput.BlockedCap(label: $0.label ?? "Model", resetsAt: $0.resetsAt) }
        let urgency = UrgencyInput(provider: input.provider, pacing: state, hourglass: a.hourglass, session: session,
                                   weeklyExhausted: a.rule == .exhausted, weeklyResetsAt: a.resetsAt, blockedCaps: blockedCaps,
                                   fault: input.fault, majorOutage: majorOutage)
        var blocked: String? = nil
        var warning: MenuBarProviderModel.SessionWarning? = nil
        switch UrgencyResolver.headline(urgency) {
        case .blocked(_, let until):
            blocked = until.map { d -> String in
                let left = d.timeIntervalSince(now)
                return left < 10 * 3600 ? TimeFormat.countdown(left) : TimeFormat.compact(left)
            } ?? "—"
        case .session(let level, let resetsAt):
            if level >= SessionLevel.amber, let s = session {
                warning = .init(level: level, used: s.used, countdown: resetsAt.map { TimeFormat.compact($0.timeIntervalSince(now)) } ?? "")
            }
        case .weekly:
            if let s = session, s.level >= .amber, let r = s.resetsAt {
                warning = .init(level: s.level, used: s.used, countdown: TimeFormat.compact(r.timeIntervalSince(now)))
            }
        }
        // Settings: the ring and countdown for any running session, not only a warning.
        let forecast = SessionForecast(window: reading.session, samples: input.samples[LimitWindow.sessionID()] ?? [], now: now)
        if warning == nil, options.alwaysShowSessionTimer, forecast.isActive, let s = session, let r = s.resetsAt {
            warning = .init(level: s.level, used: s.used, countdown: TimeFormat.compact(r.timeIntervalSince(now)))
        }
        // Settings: what the five cells measure.
        let showsSession: Bool = switch options.meterFocus {
        case .week: false
        case .session: reading.session != nil
        case .tighter: forecast.isActive && a.rule != .exhausted && (forecast.pacingState > state || (session?.level ?? .normal) >= .amber)
        }
        var cells = a.cells, shownState = state, hourglass = a.hourglass, left = a.remaining
        if showsSession {
            cells = forecast.isActive ? PacingEngine.cells(remaining: forecast.remaining) : 5
            shownState = forecast.pacingState
            hourglass = false
            left = forecast.remaining
        }
        var spoken = "\(input.provider.displayName): \(Int((a.remaining * 100).rounded())) percent left this week, \(a.rule == .exhausted ? "limit reached" : state.title.lowercased()), "
        spoken += TimeFormat.renewalCaption(a.resetsAt, now: now, calendar: calendar, locale: locale) + "."
        if showsSession { spoken += " The meter shows the 5-hour session: \(Int((forecast.remaining * 100).rounded())) percent left." }
        if let w = warning, let s = session { spoken += " 5-hour session \(Int((s.remaining * 100).rounded())) percent left, resets in \(w.countdown)." }
        if let b = blocked { spoken += " Blocked, back in \(b)." }
        if input.fault != nil { spoken += " Showing the last reading." }
        let model = MenuBarProviderModel(provider: input.provider, state: shownState, cells: cells, hourglass: hourglass,
                                         session: blocked == nil ? warning : nil, blockedCountdown: blocked,
                                         fault: input.fault != nil, spoken: spoken,
                                         percent: options.showPercent ? "\(Int((left * 100).rounded()))%" : nil,
                                         tracksSession: showsSession)
        return (model, urgency)
    }

    /// Applies the Settings mode: Both · Most urgent · Claude · Codex.
    func menuBarItems(_ inputs: [PaceInput], mode: MenuBarMode, enabled: Set<Provider>, majorOutage: [Provider: String] = [:]) -> [MenuBarProviderModel] {
        let built = inputs.filter { enabled.contains($0.provider) }.compactMap { menuBar($0, majorOutage: majorOutage[$0.provider]) }
        switch mode {
        case .both: return built.map(\.model)
        case .claude: return built.filter { $0.model.provider == .claude }.map(\.model)
        case .codex: return built.filter { $0.model.provider == .codex }.map(\.model)
        case .mostUrgent:
            guard let p = UrgencyResolver.mostUrgent(built.map(\.urgency)) else { return built.prefix(1).map(\.model) }
            return built.filter { $0.model.provider == p }.map(\.model)
        }
    }
}
