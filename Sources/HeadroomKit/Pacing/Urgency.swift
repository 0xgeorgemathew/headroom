import Foundation

/// Why a provider can't be used right now.
public enum BlockReason: Codable, Sendable, Hashable {
    case session
    case weekly
    /// A model-scoped cap for the active model is at 100% ("Fable").
    case modelCap(String)
    /// A major outage, with its description.
    case outage(String)
}

/// What a provider's headline (and the menu bar) describes: the tightest constraint wins (PLAN §2.3).
public enum ProviderHeadline: Codable, Sendable, Hashable {
    case blocked(reason: BlockReason, until: Date?)
    case session(level: SessionLevel, resetsAt: Date?)
    case weekly(PacingState)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// Everything the binding-constraint resolver needs for one provider.
public struct UrgencyInput: Sendable, Hashable {
    public var provider: Provider
    /// Smoothed weekly state; nil when there's no weekly reading.
    public var pacing: PacingState?
    public var hourglass: Bool
    public var session: SessionStatus?
    public var weeklyExhausted: Bool
    public var weeklyResetsAt: Date?
    /// Model caps at 100% that apply to the active model: (label, reset time).
    public var blockedCaps: [BlockedCap]
    public var fault: Fault?
    /// Description of a major outage, when one is active.
    public var majorOutage: String?

    public struct BlockedCap: Sendable, Hashable {
        public var label: String
        public var resetsAt: Date?
        public init(label: String, resetsAt: Date?) {
            self.label = label
            self.resetsAt = resetsAt
        }
    }

    public init(
        provider: Provider,
        pacing: PacingState?,
        hourglass: Bool = false,
        session: SessionStatus? = nil,
        weeklyExhausted: Bool = false,
        weeklyResetsAt: Date? = nil,
        blockedCaps: [BlockedCap] = [],
        fault: Fault? = nil,
        majorOutage: String? = nil
    ) {
        self.provider = provider
        self.pacing = pacing
        self.hourglass = hourglass
        self.session = session
        self.weeklyExhausted = weeklyExhausted
        self.weeklyResetsAt = weeklyResetsAt
        self.blockedCaps = blockedCaps
        self.fault = fault
        self.majorOutage = majorOutage
    }
}

/// Comparable urgency for the menu bar's "Most urgent" mode: higher is more urgent.
public struct Urgency: Comparable, Sendable, Hashable {
    public var score: Double

    public init(score: Double) { self.score = score }

    public static func < (a: Urgency, b: Urgency) -> Bool { a.score < b.score }
}

public enum UrgencyResolver {
    public static func headline(_ i: UrgencyInput) -> ProviderHeadline {
        if let s = i.session, s.level == .blocked { return .blocked(reason: .session, until: s.resetsAt) }
        if i.weeklyExhausted { return .blocked(reason: .weekly, until: i.weeklyResetsAt) }
        if let cap = i.blockedCaps.first { return .blocked(reason: .modelCap(cap.label), until: cap.resetsAt) }
        if let outage = i.majorOutage { return .blocked(reason: .outage(outage), until: nil) }
        if let s = i.session, s.level >= .amber { return .session(level: s.level, resetsAt: s.resetsAt) }
        return .weekly(i.pacing ?? .onPace)
    }

    /// Blocked > closest to the session limit > tightest pacing. Plenty with the hourglass outranks
    /// plain on-pace (the allowance is about to go unused).
    public static func urgency(_ i: UrgencyInput) -> Urgency {
        switch headline(i) {
        case .blocked:
            return Urgency(score: 1000)
        case .session(_, _):
            return Urgency(score: 500 + (i.session?.used ?? 0) * 100)
        case .weekly(let state):
            let base: Double
            switch state {
            case .veryTight: base = 40
            case .tight: base = 30
            case .onPace: base = 10
            case .plenty: base = i.hourglass ? 15 : 5
            }
            return Urgency(score: base + (i.session?.used ?? 0))
        }
    }

    /// The provider "Most urgent" mode shows. Ties go to Claude, then Codex.
    public static func mostUrgent(_ inputs: [UrgencyInput]) -> Provider? {
        inputs.max { a, b in
            let ua = urgency(a), ub = urgency(b)
            if ua != ub { return ua < ub }
            return a.provider > b.provider
        }?.provider
    }
}
