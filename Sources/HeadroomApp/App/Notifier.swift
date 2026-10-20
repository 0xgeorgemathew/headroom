import AppKit
import HeadroomKit
import UserNotifications

/// Local notifications for the moments worth an interruption: the 5-hour session nearing or
/// hitting its limit, the session coming back, the week turning tight, credits about to lapse.
/// Each event fires once; what has fired is remembered across launches.
@MainActor
final class Notifier {
    private let settings: AppSettings
    private let defaults: UserDefaults
    /// Session levels last seen per provider, to notice a warned session resetting.
    private var lastSession: [Provider: (level: SessionLevel, resetsAt: Date?)] = [:]

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
    }

    /// Notifications need a real app bundle (not `swift run`).
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    var anyEnabled: Bool { NotificationKind.allCases.contains { settings.notifies($0) } }

    /// Asks macOS for permission. Completion gets whether alerts are allowed.
    static func requestAuthorization(_ done: (@MainActor (Bool) -> Void)? = nil) {
        guard available else { done?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in done?(granted) }
        }
    }

    /// Looks at every provider's current state and posts what's new.
    func evaluate(_ inputs: [PaceInput], presenter: Presenter) {
        guard Self.available, anyEnabled else { return }
        let now = presenter.now
        for input in inputs {
            guard let reading = input.reading else { continue }
            let p = input.provider
            let name = p.displayName
            let clock: (Date) -> String = { TimeFormat.clock($0, calendar: presenter.calendar, locale: presenter.locale) }

            // 5-hour session.
            let status = SessionStatus(window: reading.session, now: now, policy: presenter.policy)
            if let s = status, let resetsAt = s.resetsAt, resetsAt > now {
                let stamp = Int(resetsAt.timeIntervalSince1970 / 600)
                if s.level == .blocked {
                    post(.sessionLimit, id: "limit.\(p.rawValue).\(stamp)", title: "\(name): 5-hour limit reached",
                         body: "Back at \(clock(resetsAt)), in \(Presenter.hoursMinutes(resetsAt.timeIntervalSince(now))).")
                } else if s.level >= .amber {
                    let f = SessionForecast(window: reading.session, samples: input.samples[LimitWindow.sessionID()] ?? [], now: now)
                    var body = "\(presenter.percent(s.remaining)) left · resets \(clock(resetsAt))."
                    if let out = f.runsOutAt { body += " At this rate it runs out around \(TimeFormat.shortClock(out, calendar: presenter.calendar, locale: presenter.locale))." }
                    post(.sessionWarning, id: "warn.\(p.rawValue).\(stamp)", title: "\(name): 5-hour session \(presenter.percent(s.used)) used", body: body)
                }
            }
            // A session that warned or blocked has reset.
            if let last = lastSession[p], last.level >= .amber, let was = last.resetsAt, was <= now {
                post(.sessionReset, id: "reset.\(p.rawValue).\(Int(was.timeIntervalSince1970 / 600))", title: "\(name): 5-hour session is back",
                     body: "A fresh session is ready. The full allowance is available again.")
            }
            if let s = status { lastSession[p] = (s.level, s.resetsAt) }

            // The week turning tight.
            if let headline = reading.headline, let resetsAt = headline.resetsAt {
                let a = PacingEngine.analyze(window: headline, samples: input.samples[headline.id] ?? [], now: now, policy: presenter.policy)
                let state = input.smoothedState ?? a.state
                if state >= .tight, a.rule != .exhausted {
                    let v = VerdictWriter.verdict(for: a, window: headline, now: now, calendar: presenter.calendar, locale: presenter.locale, state: state)
                    post(.weeklyTight, id: "week.\(p.rawValue).\(Int(resetsAt.timeIntervalSince1970 / 3600)).\(state.rawValue)",
                         title: "\(name): \(state.title.lowercased()) this week", body: v.primary)
                }
            }

            // Reset credits lapsing within two days.
            for credit in reading.resetCredits {
                guard let exp = credit.expiresAt, exp > now, exp.timeIntervalSince(now) < 48 * 3600 else { continue }
                post(.creditsExpiring, id: "credit.\(p.rawValue).\(Int(exp.timeIntervalSince1970))", title: "\(name): a reset credit lapses soon",
                     body: "It expires \(TimeFormat.shortDayTime(exp, now: now, calendar: presenter.calendar, locale: presenter.locale)). Headroom never redeems one for you.")
            }
        }
    }

    private func post(_ kind: NotificationKind, id: String, title: String, body: String) {
        guard settings.notifies(kind) else { return }
        var sent = defaults.stringArray(forKey: "notifiedEvents") ?? []
        guard !sent.contains(id) else { return }
        sent.append(id)
        defaults.set(Array(sent.suffix(200)), forKey: "notifiedEvents")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = kind.rawValue
        if kind == .sessionLimit || kind == .sessionWarning { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
