import AppKit
import HeadroomKit

/// User preferences (Settings window). Backed by UserDefaults; nothing secret is stored here.
@MainActor
final class AppSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func changed() { onChange?() }

    var enabledProviders: Set<Provider> {
        get {
            let disabled = Set((defaults.stringArray(forKey: "disabledProviders") ?? []).compactMap(Provider.init(rawValue:)))
            return Set(Provider.allCases).subtracting(disabled)
        }
        set {
            defaults.set(Provider.allCases.filter { !newValue.contains($0) }.map(\.rawValue), forKey: "disabledProviders")
            changed()
        }
    }

    var menuBarMode: MenuBarMode {
        get { defaults.string(forKey: "menuBarMode").flatMap(MenuBarMode.init(rawValue:)) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "menuBarMode"); changed() }
    }

    /// Monthly plan price override in USD (nil = the plan's list price).
    func planPriceOverride(_ p: Provider) -> Double? {
        let v = defaults.double(forKey: "planPrice.\(p.rawValue)")
        return defaults.object(forKey: "planPrice.\(p.rawValue)") == nil ? nil : v
    }

    func setPlanPriceOverride(_ value: Double?, for p: Provider) {
        if let value { defaults.set(value, forKey: "planPrice.\(p.rawValue)") } else { defaults.removeObject(forKey: "planPrice.\(p.rawValue)") }
        changed()
    }

    var statusChecks: Bool {
        get { defaults.object(forKey: "statusChecks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "statusChecks"); changed() }
    }

    var costOnShares: Bool {
        get { defaults.object(forKey: "costOnShares") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "costOnShares"); changed() }
    }

    // MARK: Welcome

    /// Set once the welcome window has been finished (or skipped).
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    // MARK: 5-hour session

    /// Used share at which the 5-hour session starts warning (amber). 75% by default.
    var sessionWarnAt: Double {
        get { (defaults.object(forKey: "sessionWarnAt") as? Double).map { min(max($0, 0.3), 0.95) } ?? 0.75 }
        set { defaults.set(newValue, forKey: "sessionWarnAt"); changed() }
    }

    static let sessionWarnChoices: [Double] = [0.5, 0.6, 0.75, 0.9]

    var sessionDetail: SessionDetail {
        get { defaults.string(forKey: "sessionDetail").flatMap(SessionDetail.init(rawValue:)) ?? .detailed }
        set { defaults.set(newValue.rawValue, forKey: "sessionDetail"); changed() }
    }

    var policy: PacingPolicy { .sessionWarning(at: sessionWarnAt) }

    // MARK: Pace card

    /// The five-cell meter and the graph, for the week and the 5-hour session. All on by default.
    func shows(_ part: CardPart) -> Bool {
        defaults.object(forKey: "show.\(part.rawValue)") as? Bool ?? true
    }

    func setShows(_ part: CardPart, _ on: Bool) {
        defaults.set(on, forKey: "show.\(part.rawValue)")
        changed()
    }

    // MARK: Menu bar extras

    var meterFocus: MeterFocus {
        get { defaults.string(forKey: "meterFocus").flatMap(MeterFocus.init(rawValue:)) ?? .week }
        set { defaults.set(newValue.rawValue, forKey: "meterFocus"); changed() }
    }

    /// Show the 5-hour ring and countdown whenever a session is running, not only near the limit.
    var alwaysShowSessionTimer: Bool {
        get { defaults.bool(forKey: "alwaysShowSessionTimer") }
        set { defaults.set(newValue, forKey: "alwaysShowSessionTimer"); changed() }
    }

    var showPercentInMenuBar: Bool {
        get { defaults.bool(forKey: "showPercentInMenuBar") }
        set { defaults.set(newValue, forKey: "showPercentInMenuBar"); changed() }
    }

    var appearance: AppAppearance {
        get { defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance"); changed() }
    }

    /// Everything the presenters need from Settings.
    var presentation: PresentationOptions {
        PresentationOptions(sessionDetail: sessionDetail, meterFocus: meterFocus, alwaysShowSessionTimer: alwaysShowSessionTimer,
                            showPercent: showPercentInMenuBar, parts: Set(CardPart.allCases.filter(shows)))
    }

    // MARK: Notifications

    func notifies(_ kind: NotificationKind) -> Bool {
        defaults.object(forKey: "notify.\(kind.rawValue)") as? Bool ?? kind.defaultOn
    }

    func setNotifies(_ kind: NotificationKind, _ on: Bool) {
        defaults.set(on, forKey: "notify.\(kind.rawValue)")
        changed()
    }

    /// User-set CLI paths (Settings → Command-line tools).
    func cliPath(_ tool: String) -> String? {
        let v = defaults.string(forKey: "cliPath.\(tool)")
        return (v?.isEmpty ?? true) ? nil : v
    }

    func setCLIPath(_ path: String?, for tool: String) {
        defaults.set(path, forKey: "cliPath.\(tool)")
        changed()
    }

    // Popover view state (remembered between openings).
    var activityMode: ActivityMode {
        get { ActivityMode(rawValue: defaults.integer(forKey: "activityMode")) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: "activityMode") }
    }

    var activityRange: ActivityRange {
        get { ActivityRange(rawValue: defaults.integer(forKey: "activityRange")) ?? .day }
        set { defaults.set(newValue.rawValue, forKey: "activityRange") }
    }

    var breakdown: BreakdownKind {
        get { BreakdownKind(rawValue: defaults.integer(forKey: "breakdown")) ?? .model }
        set { defaults.set(newValue.rawValue, forKey: "breakdown") }
    }

    var lastTab: Int {
        get { defaults.integer(forKey: "lastTab") }
        set { defaults.set(newValue, forKey: "lastTab") }
    }
}

/// How the 5-hour session appears on each Pace card.
enum SessionDetail: String, CaseIterable, Sendable {
    /// Its own panel with a timeline and a forecast; it moves to the top once it warns.
    case detailed
    /// A row in the details list, and a banner once it warns.
    case compact

    var title: String { self == .detailed ? "Detailed" : "Compact" }
}

/// The optional pieces of a Pace card.
enum CardPart: String, CaseIterable, Sendable {
    case weekMeter, weekGraph, sessionMeter, sessionGraph
}

/// What the five menu bar cells measure.
enum MeterFocus: String, CaseIterable, Sendable {
    case week, session, tighter

    var title: String {
        switch self {
        case .week: "This week"
        case .session: "5-hour session"
        case .tighter: "Whichever is tighter"
        }
    }
}

enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String { rawValue.capitalized }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum NotificationKind: String, CaseIterable, Sendable {
    case sessionWarning, sessionLimit, sessionReset, weeklyTight, creditsExpiring

    var defaultOn: Bool { self != .weeklyTight }

    var title: String {
        switch self {
        case .sessionWarning: "5-hour session almost used"
        case .sessionLimit: "5-hour limit reached"
        case .sessionReset: "5-hour session reset"
        case .weeklyTight: "Week getting tight"
        case .creditsExpiring: "Reset credits about to lapse"
        }
    }
}

/// Settings that shape what the cards and the menu bar show.
struct PresentationOptions: Equatable, Sendable {
    var sessionDetail: SessionDetail = .detailed
    var meterFocus: MeterFocus = .week
    var alwaysShowSessionTimer = false
    var showPercent = false
    /// Meters and graphs to draw on each Pace card.
    var parts: Set<CardPart> = Set(CardPart.allCases)
}
