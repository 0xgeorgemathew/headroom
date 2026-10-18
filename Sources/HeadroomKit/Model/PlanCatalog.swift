import Foundation

/// Maps raw plan identifiers to the plan pill and default monthly list price (PLAN §6, §14.4).
/// Prices are defaults only; Settings can override them.
public enum PlanCatalog {
    public static func claude(subscriptionType: String?, rateLimitTier: String?) -> PlanInfo? {
        guard let raw = subscriptionType?.lowercased(), !raw.isEmpty else { return nil }
        let tier = rateLimitTier?.lowercased() ?? ""
        let maxMultiple: String? = tier.contains("max_20x") ? "20" : tier.contains("max_5x") ? "5" : nil
        switch raw {
        case "pro":
            return PlanInfo(raw: raw, tier: rateLimitTier, pill: "PRO", monthlyPriceUSD: 20)
        case "max", "max_5x", "max_20x":
            let multiple = maxMultiple ?? (raw == "max_20x" ? "20" : "5")
            return PlanInfo(raw: raw, tier: rateLimitTier, pill: "MAX \(multiple)×", monthlyPriceUSD: multiple == "20" ? 200 : 100)
        case "team":
            return PlanInfo(raw: raw, tier: rateLimitTier, pill: "TEAM", monthlyPriceUSD: maxMultiple == nil ? 30 : 150)
        case "free":
            return PlanInfo(raw: raw, tier: rateLimitTier, pill: "FREE", monthlyPriceUSD: 0)
        default:
            if raw.hasPrefix("enterprise") {
                return PlanInfo(raw: raw, tier: rateLimitTier, pill: "ENTERPRISE", isEnterprise: true)
            }
            return PlanInfo(raw: raw, tier: rateLimitTier, pill: raw.uppercased().replacingOccurrences(of: "_", with: " "))
        }
    }

    public static func codex(planType: String?) -> PlanInfo? {
        guard let raw = planType?.lowercased(), !raw.isEmpty, raw != "unknown" else { return nil }
        switch raw {
        case "free": return PlanInfo(raw: raw, pill: "FREE", monthlyPriceUSD: 0)
        case "go": return PlanInfo(raw: raw, pill: "GO", monthlyPriceUSD: 8)
        case "plus": return PlanInfo(raw: raw, pill: "PLUS", monthlyPriceUSD: 20)
        case "prolite": return PlanInfo(raw: raw, pill: "PRO", monthlyPriceUSD: 100)
        case "pro": return PlanInfo(raw: raw, pill: "PRO", monthlyPriceUSD: 200)
        case "promax": return PlanInfo(raw: raw, pill: "PRO MAX")
        case "team", "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            return PlanInfo(raw: raw, pill: "BUSINESS", monthlyPriceUSD: 25)
        case "edu", "edu_plus", "edu_pro":
            return PlanInfo(raw: raw, pill: "EDU")
        default:
            if raw.hasPrefix("enterprise") || raw == "ent26" {
                return PlanInfo(raw: raw, pill: "ENTERPRISE", isEnterprise: true)
            }
            return PlanInfo(raw: raw, pill: raw.uppercased().replacingOccurrences(of: "_", with: " "))
        }
    }
}
