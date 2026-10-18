import Foundation
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
