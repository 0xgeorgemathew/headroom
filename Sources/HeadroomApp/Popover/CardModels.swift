import AppKit
import HeadroomKit

/// Presentation models: everything a card draws, already formatted. Built by `Presenter`
/// from live state or by `DemoScenarios` from fixtures, so every UI state is reachable.

struct Freshness: Equatable {
    enum Status: Equatable { case fresh, stale, error }
    var text: String
    var status: Status
    /// Hover text (the fault reason when red).
    var tooltip: String?
}

struct SessionBannerModel: Equatable {
    var level: SessionLevel
    /// Used fraction 0…1 for the ring.
    var used: Double
    var title: String
    var subtitle: String
    var countdown: String
    var caption: String
}

struct HeroModel: Equatable {
    var percentLeft: Int
    var label: String
    var renewValue: String
    var renewCaption: String
    var hourglass: Bool
}

struct MeterModel: Equatable {
    var state: PacingState
    var cells: Int
    /// Even-pace caret position along the track (τ), nil to hide.
    var caret: Double?
    /// 1 normally, 0.5 for faults, 0.4 when blocked.
    var opacity: Double
}

struct GlideModel: Equatable {
    struct Point: Equatable { var t: Double; var used: Double }
    /// Window length in hours (168 for a week).
    var hours: Double
    /// Local window start, for day boundaries and labels.
    var windowStart: Date
    var nowT: Double
    /// Used fraction history (t in hours since start). Gaps longer than 2 h are drawn dotted.
    var points: [Point]
    /// Projection end: hour and remaining fraction there.
    var projectionEnd: (t: Double, remaining: Double)
    /// When the projection runs out before renewal.
    var runsOut: Bool
    var endLabel: String?
    var state: PacingState
    /// Override line color (history view uses the brand color).
    var brandLine: Provider? = nil

    static func == (a: GlideModel, b: GlideModel) -> Bool {
        a.hours == b.hours && a.windowStart == b.windowStart && a.nowT == b.nowT && a.points == b.points
            && a.projectionEnd.t == b.projectionEnd.t && a.projectionEnd.remaining == b.projectionEnd.remaining
            && a.runsOut == b.runsOut && a.endLabel == b.endLabel && a.state == b.state && a.brandLine == b.brandLine
    }
}

struct VerdictModel: Equatable {
    var state: PacingState
    var title: String
    var multiple: String
    var primary: String
    var secondary: String
}

struct CalloutModel: Equatable {
    enum Kind: Equatable { case capEmpty, capTight, earlyReset }
    var kind: Kind
    var text: String
}

struct DetailRowModel: Equatable {
    enum Icon: Equatable {
        case ring(used: Double, level: SessionLevel)
        case hourglass(highlight: Bool)
        case coin(Provider)
    }
    var icon: Icon
    var label: String
    var value: String
    var suffix: String?
    var highlight: Bool = false
    var tooltip: String? = nil
}

struct FaultBannerModel: Equatable {
    var message: String
    var detail: String?
}

struct PaceCardModel: Equatable {
    var provider: Provider
    var plan: String?
    var freshness: Freshness
    var session: SessionBannerModel?
    var hero: HeroModel?
    var meter: MeterModel?
    var glide: GlideModel?
    var verdict: VerdictModel?
    var callout: CalloutModel?
    var rows: [DetailRowModel]
    var fault: FaultBannerModel?
}

// MARK: - Activity

enum ActivityRange: Int, CaseIterable, Equatable { case day, week, month
    var label: String { ["24H", "7D", "30D"][rawValue] }
}

enum ActivityMode: Int, Equatable { case all, newOnly }

enum BreakdownKind: Int, CaseIterable, Equatable { case model, project, tokenClass
    var title: String { ["By model", "By project", "By token class"][rawValue] }
}

struct ActivityBar: Equatable {
    var start: Date
    var end: Date
    var tokens: TokenCounts
    var micros: Int64
}

struct BreakdownRow: Equatable {
    var name: String
    var micros: Int64
    var share: Double
}

struct ActivityCardModel: Equatable {
    var provider: Provider
    var bars: [ActivityBar]
    /// Selected bar index range [lower, upper).
    var selection: Range<Int>
    var axisLabels: [(index: Int, text: String)]
    var spanLabel: String
    var spanLong: String
    var totals: TokenCounts
    var micros: Int64
    var breakdown: [BreakdownKind: [BreakdownRow]]
    var footnote: String?

    static func == (a: ActivityCardModel, b: ActivityCardModel) -> Bool {
        a.provider == b.provider && a.bars == b.bars && a.selection == b.selection && a.spanLabel == b.spanLabel
            && a.totals == b.totals && a.micros == b.micros && a.breakdown == b.breakdown
            && a.axisLabels.map(\.index) == b.axisLabels.map(\.index) && a.axisLabels.map(\.text) == b.axisLabels.map(\.text)
    }
}

// MARK: - Past weeks

struct WeekColumn: Equatable {
    var used: Double
    var projected: Double? = nil
    var ranOutHoursEarly: Int? = nil
    var sessionHits: Int = 0
    var earlyResets: Int = 0
    var isCurrent: Bool = false
    var caption: String
}

struct PastWeeksModel: Equatable {
    var provider: Provider
    var weeks: [WeekColumn]
    /// Index after which a plan change happened, with the new plan's pill.
    var planChange: (after: Int, pill: String)?
    var chips: [(color: ChipDot, text: String)]
    var collecting: Bool

    enum ChipDot: Equatable { case rose, azure, spark }

    static func == (a: PastWeeksModel, b: PastWeeksModel) -> Bool {
        a.provider == b.provider && a.weeks == b.weeks && a.planChange?.after == b.planChange?.after
            && a.planChange?.pill == b.planChange?.pill && a.chips.map(\.text) == b.chips.map(\.text) && a.collecting == b.collecting
    }
}

struct FooterModel: Equatable {
    var text: String
    var status: Freshness.Status
}
