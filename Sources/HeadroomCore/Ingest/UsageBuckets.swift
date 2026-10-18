import Foundation
import HeadroomKit

/// API-equivalent cost of usage, split by token class, in integer micro-dollars (PLAN §6).
public struct ClassCost: Codable, Sendable, Hashable {
    public var input: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64
    public var output: Int64

    public init(input: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0, output: Int64 = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public static let zero = ClassCost()
    public var total: Int64 { input + cacheWrite + cacheRead + output }

    public static func + (a: ClassCost, b: ClassCost) -> ClassCost {
        ClassCost(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite,
                  cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }

    public static func - (a: ClassCost, b: ClassCost) -> ClassCost {
        ClassCost(input: a.input - b.input, cacheWrite: a.cacheWrite - b.cacheWrite,
                  cacheRead: a.cacheRead - b.cacheRead, output: a.output - b.output)
    }
}

/// Price of one event. `priced == false` for models missing from the price table.
public struct EventPrice: Sendable, Hashable {
    public var cost: ClassCost
    public var priced: Bool

    public init(cost: ClassCost, priced: Bool) {
        self.cost = cost
        self.priced = priced
    }

    public static let unpriced = EventPrice(cost: .zero, priced: false)
}

/// Injected pricing function (implemented by the pricing engine).
public typealias EventPricer = @Sendable (UsageEvent) -> EventPrice

/// Aggregated usage for one provider, quarter-hour slot, model and project.
public struct SlotKey: Hashable, Sendable {
    public var provider: Provider
    /// `floor(epochSeconds / 900)`. Quarter-hour slots align with local hours and days in every time zone.
    public var slot: Int32
    public var model: UInt16
    public var project: UInt16
}

public struct UsageTotals: Sendable, Hashable {
    public var tokens = TokenCounts.zero
    public var cost = ClassCost.zero
    /// Tokens on models with no price, included in `tokens` but not in `cost`.
    public var unpricedTokens: Int64 = 0
    public var events: Int = 0

    public init() {}

    public var micros: Int64 { cost.total }
    public var dollars: Double { Double(cost.total) / 1_000_000 }

    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        var r = a
        r.tokens += b.tokens
        r.cost = r.cost + b.cost
        r.unpricedTokens += b.unpricedTokens
        r.events += b.events
        return r
    }

    public static func - (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        var r = a
        r.tokens -= b.tokens
        r.cost = r.cost - b.cost
        r.unpricedTokens -= b.unpricedTokens
        r.events -= b.events
        return r
    }
}

/// Read-only, copy-on-write view of local usage, safe to query from the main thread.
public struct UsageBuckets: Sendable {
    public static let slotSeconds: Int = 900

    var slots: [SlotKey: UsageTotals] = [:]
    var models: [String] = []
    var projects: [String] = []

    public init() {}

    public static func slot(for date: Date) -> Int32 {
        Int32(clamping: Int((date.timeIntervalSince1970 / Double(slotSeconds)).rounded(.down)))
    }

    public var isEmpty: Bool { slots.isEmpty }

    /// Every non-empty slot with its model and project names (bench, export, tests).
    public var allSlots: [(key: SlotKey, model: String, project: String, totals: UsageTotals)] {
        slots.map { k, v in
            (k, Int(k.model) < models.count ? models[Int(k.model)] : "unknown",
             Int(k.project) < projects.count ? projects[Int(k.project)] : "—", v)
        }
    }

    /// Usage in [from, to), rounded to quarter-hour slots.
    public func totals(_ provider: Provider? = nil, from: Date, to: Date) -> UsageTotals {
        let a = Self.slot(for: from), b = Self.slot(for: to)
        var t = UsageTotals()
        for (k, v) in slots where k.slot >= a && k.slot < b && (provider == nil || k.provider == provider) {
            t = t + v
        }
        return t
    }

    /// Usage per bin for consecutive `edges` (n edges → n−1 bins).
    public func series(_ provider: Provider? = nil, edges: [Date]) -> [UsageTotals] {
        guard edges.count >= 2 else { return [] }
        let bounds = edges.map(Self.slot(for:))
        var out = [UsageTotals](repeating: UsageTotals(), count: edges.count - 1)
        let lo = bounds.first!, hi = bounds.last!
        for (k, v) in slots where k.slot >= lo && k.slot < hi && (provider == nil || k.provider == provider) {
            // Binary search the bin.
            var l = 0, r = bounds.count - 1
            while r - l > 1 {
                let m = (l + r) / 2
                if bounds[m] <= k.slot { l = m } else { r = m }
            }
            out[l] = out[l] + v
        }
        return out
    }

    public enum Dimension: Sendable { case model, project }

    /// Usage grouped by model or project, most expensive first (then most tokens).
    public func breakdown(_ provider: Provider? = nil, by dimension: Dimension, from: Date, to: Date) -> [(name: String, totals: UsageTotals)] {
        let a = Self.slot(for: from), b = Self.slot(for: to)
        var acc: [UInt16: UsageTotals] = [:]
        for (k, v) in slots where k.slot >= a && k.slot < b && (provider == nil || k.provider == provider) {
            let id = dimension == .model ? k.model : k.project
            acc[id, default: UsageTotals()] = acc[id, default: UsageTotals()] + v
        }
        let names = dimension == .model ? models : projects
        return acc.map { (name: Int($0.key) < names.count ? names[Int($0.key)] : "unknown", totals: $0.value) }
            .sorted {
                if $0.totals.micros != $1.totals.micros { return $0.totals.micros > $1.totals.micros }
                if $0.totals.tokens.total != $1.totals.tokens.total { return $0.totals.tokens.total > $1.totals.tokens.total }
                return $0.name < $1.name
            }
    }

    /// Models with unpriced tokens in the range, with their token counts.
    public func unpricedModels(_ provider: Provider? = nil, from: Date, to: Date) -> [(name: String, tokens: Int64)] {
        breakdown(provider, by: .model, from: from, to: to)
            .filter { $0.totals.unpricedTokens > 0 }
            .map { (name: $0.name, tokens: $0.totals.unpricedTokens) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// The newest slot with usage for a provider, as a date.
    public func lastActivity(_ provider: Provider? = nil) -> Date? {
        var best: Int32?
        for k in slots.keys where provider == nil || k.provider == provider {
            if best == nil || k.slot > best! { best = k.slot }
        }
        return best.map { Date(timeIntervalSince1970: TimeInterval(Int($0) * Self.slotSeconds)) }
    }

    // MARK: Bin layouts (PLAN §7: 24 hourly, 7 days in 4-hour bins, 30 daily)

    /// `count` local-hour bins ending with the hour containing `now`.
    public static func hourEdges(endingAt now: Date, count: Int = 24, calendar: Calendar = .current) -> [Date] {
        let startOfHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let end = calendar.date(byAdding: .hour, value: 1, to: startOfHour)!
        return (0...count).map { calendar.date(byAdding: .hour, value: $0 - count, to: end)! }
    }

    /// Seven local days in 4-hour bins (42 bins), ending with the bin containing `now`.
    public static func fourHourEdges(endingAt now: Date, days: Int = 7, calendar: Calendar = .current) -> [Date] {
        let day = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        let binEnd = calendar.date(byAdding: .hour, value: (hour / 4 + 1) * 4, to: day)!
        let count = days * 6
        return (0...count).map { calendar.date(byAdding: .hour, value: ($0 - count) * 4, to: binEnd)! }
    }

    /// `count` local-day bins ending with today.
    public static func dayEdges(endingAt now: Date, count: Int = 30, calendar: Calendar = .current) -> [Date] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return (0...count).map { calendar.date(byAdding: .day, value: $0 - count, to: end)! }
    }
}

/// One deduplicated event's stored contribution. The ledger keeps every event in the
/// retention window, so dedupe is exact and a pricing change can reprice history.
struct Contribution: Sendable, Hashable {
    var keyHash: UInt64
    var provider: Provider
    var slot: Int32
    var model: UInt16
    var project: UInt16
    var file: UInt32
    var timestamp: Double
    var tokens: TokenCounts
    var speed: Speed
    var cost: ClassCost
    var priced: Bool

    var totals: UsageTotals {
        var t = UsageTotals()
        t.tokens = tokens
        t.cost = cost
        t.unpricedTokens = priced ? 0 : tokens.total
        t.events = 1
        return t
    }
}

/// The event ledger plus the buckets derived from it.
struct UsageLedger: Sendable {
    var entries = ContributionTable()
    var buckets = UsageBuckets()
    var files: [String] = []
    private var modelIndex: [String: UInt16] = [:]
    private var projectIndex: [String: UInt16] = [:]
    private var fileIndex: [String: UInt32] = [:]

    init() {}

    init(table: ContributionTable, models: [String], projects: [String], files: [String]) {
        buckets.models = models
        buckets.projects = projects
        self.files = files
        for (i, m) in models.enumerated() { modelIndex[m] = UInt16(i) }
        for (i, p) in projects.enumerated() { projectIndex[p] = UInt16(i) }
        for (i, f) in files.enumerated() { fileIndex[f] = UInt32(i) }
        self.entries = table
        table.forEachPacked { apply($0.contribution, sign: 1) }
    }

    init(entries: [Contribution], models: [String], projects: [String], files: [String]) {
        buckets.models = models
        buckets.projects = projects
        self.files = files
        for (i, m) in models.enumerated() { modelIndex[m] = UInt16(i) }
        for (i, p) in projects.enumerated() { projectIndex[p] = UInt16(i) }
        for (i, f) in files.enumerated() { fileIndex[f] = UInt32(i) }
        self.entries = ContributionTable(entries)
        for c in self.entries.values { apply(c, sign: 1) }
    }

    static func hash(_ key: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    mutating func model(_ name: String) -> UInt16 {
        if let i = modelIndex[name] { return i }
        let i = UInt16(clamping: buckets.models.count)
        buckets.models.append(name)
        modelIndex[name] = i
        return i
    }

    mutating func project(_ name: String?) -> UInt16 {
        let name = name ?? "—"
        if let i = projectIndex[name] { return i }
        let i = UInt16(clamping: buckets.projects.count)
        buckets.projects.append(name)
        projectIndex[name] = i
        return i
    }

    mutating func file(_ path: String) -> UInt32 {
        if let i = fileIndex[path] { return i }
        let i = UInt32(files.count)
        files.append(path)
        fileIndex[path] = i
        return i
    }

    private mutating func apply(_ c: Contribution, sign: Int) {
        let key = SlotKey(provider: c.provider, slot: c.slot, model: c.model, project: c.project)
        let current = buckets.slots[key] ?? UsageTotals()
        let next = sign > 0 ? current + c.totals : current - c.totals
        if next.events <= 0 {
            buckets.slots[key] = nil
        } else {
            buckets.slots[key] = next
        }
    }

    /// Adds an event. A repeated key keeps the last line within a file; across files the later
    /// timestamp wins, with the file path breaking ties (deterministic under parallel scans).
    /// Returns true when the ledger changed.
    @discardableResult
    mutating func add(_ event: UsageEvent, file path: String, price: EventPrice) -> Bool {
        let fileID = file(path)
        let key = event.dedupeKey ?? "@\(path):\(event.timestamp.timeIntervalSince1970)"
        let h = Self.hash(key)
        let ts = event.timestamp.timeIntervalSince1970
        if let old = entries[h] {
            if old.file != fileID {
                let oldPath = Int(old.file) < files.count ? files[Int(old.file)] : ""
                if ts < old.timestamp || (ts == old.timestamp && path < oldPath) { return false }
            }
            apply(old, sign: -1)
        }
        let c = Contribution(
            keyHash: h, provider: event.provider, slot: UsageBuckets.slot(for: event.timestamp),
            model: model(event.model), project: project(event.project), file: fileID,
            timestamp: ts, tokens: event.tokens, speed: event.speed, cost: price.cost, priced: price.priced)
        entries[h] = c
        apply(c, sign: 1)
        return true
    }

    mutating func retract(keys: [String]) {
        for k in keys {
            let h = Self.hash(k)
            if let old = entries.removeValue(forKey: h) { apply(old, sign: -1) }
        }
    }

    /// Drops events older than `cutoff` (retention).
    mutating func prune(before cutoff: Date) {
        let t = cutoff.timeIntervalSince1970
        for c in entries.removeAll(where: { $0.timestamp < t }) { apply(c, sign: -1) }
    }

    /// Recomputes every event's cost, e.g. after `pricing.override.json` changes.
    mutating func reprice(_ pricer: EventPricer) {
        buckets.slots = [:]
        let models = buckets.models
        var repriced: [Contribution] = []
        entries.update { c in
            let event = UsageEvent(
                provider: c.provider, timestamp: Date(timeIntervalSince1970: c.timestamp),
                model: Int(c.model) < models.count ? models[Int(c.model)] : "unknown",
                project: nil, tokens: c.tokens, speed: c.speed, dedupeKey: nil)
            let p = pricer(event)
            c.cost = p.cost
            c.priced = p.priced
            repriced.append(c)
        }
        for c in repriced { apply(c, sign: 1) }
    }
}
