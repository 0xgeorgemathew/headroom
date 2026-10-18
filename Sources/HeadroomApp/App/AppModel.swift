import AppKit
import HeadroomCore
import HeadroomKit
import os

/// Diagnostics: counts and timings only (no paths, tokens or account data).
let diag = Logger(subsystem: "com.headroom.app", category: "engine")

/// Persisted between launches (`state.plist`): history and last good readings. The ingestion
/// state (cursors, ledger) lives in `ingest.plist`, which the scan child reads and writes directly.
struct PersistedState: Codable, Sendable {
    var version = 2
    var history = HistoryStore()
    var lastGood: [String: LimitReading] = [:]
    var claudeRefreshLastRun: Date?
    var codexAccountKey: String?
}

/// Owns every Core component and turns their results into presentation input. Main actor;
/// the Core actors do the work off the main thread.
@MainActor
final class AppModel {
    let settings: AppSettings
    private(set) var history = HistoryStore()
    private(set) var faults: [Provider: FaultMachine] = [:]
    private(set) var buckets = UsageBuckets()
    private(set) var serviceStatus: [Provider: ServiceStatus] = [:]
    private(set) var firstScanDone = false
    private(set) var scanProgress: String?
    var popoverOpen = false { didSet { if popoverOpen { popoverOpened() } } }

    /// Called on the main actor whenever anything visible changed.
    var onChange: (() -> Void)?

    private let store = PlistStore<PersistedState>.standard(named: "state.plist")
    private let ingestStore = PlistStore<IngestState>.standard(named: "ingest.plist")
    private var saver: DebouncedSaver?
    private var ingestor: LogIngestor
    private var watcher: LogWatcher?
    private let resolver = CLIResolver()
    private var claude: ClaudeUsageClient!
    private var codex: CodexAppServerClient!
    private var refresher: ClaudeRefresher!
    private let statusClient = StatusClient()
    private var scheduler: AdaptiveScheduler
    private let timer = SchedulerTimer()
    private var minuteTimer: Timer?
    private let reachability = NWPathReachability()
    private var refreshObserver: RefreshObserver?
    private var inFlight: Set<Provider> = []
    private var codexAccountKey: String?
    private var pricing: PricingEngine
    private var pricingOverrideStamp: Date?
    private var lastSnapshotBody: Data?
    private var observers: [NSObjectProtocol] = []
    private let snapshotWriter = SnapshotWriter()

    init(settings: AppSettings) {
        self.settings = settings
        let persisted = PlistStore<PersistedState>.standard(named: "state.plist").load() ?? PersistedState()
        history = persisted.history
        codexAccountKey = persisted.codexAccountKey
        for p in Provider.allCases {
            faults[p] = FaultMachine(provider: p, lastGood: persisted.lastGood[p.rawValue])
        }
        pricing = PricingEngine.standard()
        pricingOverrideStamp = Self.overrideStamp()
        let engine = pricing
        // Empty until the first scan; the scan child loads `ingest.plist` itself (see `fullScan`).
        ingestor = LogIngestor(pricer: Self.pricer(engine), state: nil)
        scheduler = AdaptiveScheduler(enabled: settings.enabledProviders, statusChecksEnabled: settings.statusChecks)

        let resolver = self.resolver
        refresher = ClaudeRefresher(lastRun: persisted.claudeRefreshLastRun) { await resolver.path(for: .claude) }
        claude = ClaudeUsageClient(refresher: refresher)
        codex = CodexAppServerClient { await resolver.path(for: .codex) }
    }

    static func pricer(_ engine: PricingEngine) -> EventPricer {
        { event in
            let c = engine.price(event)
            return EventPrice(cost: ClassCost(input: c.input, cacheWrite: c.cacheWrite, cacheRead: c.cacheRead, output: c.output), priced: c.priced)
        }
    }

    private static func overrideStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: PriceTable.defaultOverrideURL.path))?[.modificationDate] as? Date
    }

    // MARK: Lifecycle

    func start() {
        saver = DebouncedSaver(delay: .seconds(300)) { [weak self] in await self?.save() }
        Task { await applyCLIOverrides() }
        startObservers()
        reachability.start { [weak self] satisfied in
            Task { @MainActor in self?.pathChanged(satisfied) }
        }
        refreshObserver = RefreshObserver { [weak self] in
            Task { @MainActor in self?.refreshNow() }
        }
        Task { await firstScan() }
        // Read limits right away on launch.
        scheduler.refreshNow()
        tick()
    }

    func applyCLIOverrides() async {
        await resolver.setOverride(settings.cliPath("claude"), for: .claude)
        await resolver.setOverride(settings.cliPath("codex"), for: .codex)
        await resolver.invalidate()
    }

    func settingsChanged() {
        scheduler.enabled = settings.enabledProviders
        scheduler.statusChecksEnabled = settings.statusChecks
        if !settings.statusChecks { serviceStatus = [:]; for p in Provider.allCases { faults[p]?.applyStatus(nil) } }
        Task {
            await applyCLIOverrides()
            // CLI-missing faults retry on settings changes.
            scheduler.refreshNow()
            tick()
        }
        changed()
    }

    private func firstScan() async {
        scanProgress = "Reading local logs…"
        changed()
        await fullScan()
        firstScanDone = true
        scanProgress = nil
        await absorbPassiveCodex()
        changed()
        await saver?.schedule()
        let standardRoots = LogRoots.standard()
        let roots = standardRoots.claude + standardRoots.codex
        watcher = LogWatcher(roots: roots, latency: 3) { [weak self] paths, rescan in
            Task { @MainActor in await self?.logsChanged(paths: paths, rescan: rescan) }
        }
        _ = watcher?.start()
    }

    /// Runs a full scan in a child process when possible (see `ScanChild`), in-process otherwise.
    private func fullScan() async {
        let t0 = Date()
        defer { diag.notice("full scan \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s") }
        if firstScanDone { await saveIngest() } // hand the child our latest cursors
        if Bundle.main.bundleURL.pathExtension == "app", let scanned = await ScanChild.scan(stateURL: ingestStore.url) {
            ingestor = LogIngestor(pricer: Self.pricer(pricing), state: scanned)
        } else {
            if !firstScanDone, let saved = ingestStore.load() { ingestor = LogIngestor(pricer: Self.pricer(pricing), state: saved) }
            _ = await ingestor.scanAll()
            await saveIngest()
        }
        buckets = await ingestor.buckets()
        await mapLedger()
    }

    private var ledgerURL: URL { ingestStore.url.deletingLastPathComponent().appendingPathComponent("ledger.bin") }

    /// Keeps the ledger file-backed so its pages don't count toward the resident footprint.
    private func mapLedger() async {
        await ingestor.mapLedger(file: ledgerURL)
        Memory.relieve()
    }

    private func saveIngest() async {
        let state = await ingestor.exportState()
        try? ingestStore.save(state)
        await mapLedger()
    }

    private func logsChanged(paths: [String], rescan: Bool) async {
        if rescan {
            diag.notice("watcher asked for a rescan (\(paths.count) paths)")
            await fullScan()
        } else {
            let report = await ingestor.ingest(paths: paths)
            diag.notice("ingest files=\(report.filesRead) bytes=\(report.bytesProcessed) events=\(report.eventsAdded) \(report.seconds, format: .fixed(precision: 3))s")
            guard report.eventsAdded > 0 else { return }
            buckets = await ingestor.buckets()
        }
        scheduler.logActivity(at: Date())
        await absorbPassiveCodex()
        // Signed-out faults retry on log activity.
        for p in Provider.allCases where faults[p]?.retryPolicy?.onLogActivity == true { scheduler.refreshNow([p]) }
        changed()
        await saver?.schedule()
        tick()
    }

    /// Fresh `rate_limits` from an `openai`-provider Codex session update the Codex reading without a spawn.
    private func absorbPassiveCodex() async {
        guard settings.enabledProviders.contains(.codex),
              let passive = await ingestor.passiveLimits(trustedOnly: true),
              let reading = passive.reading(accountKey: codexAccountKey) else { return }
        let current = faults[.codex]?.lastGood
        guard reading.fetchedAt > (current?.fetchedAt ?? .distantPast) else { return }
        var merged = reading
        // Keep the plan, credits and caps from the last full read for the same account.
        if let current, current.accountKey == reading.accountKey {
            merged.resetCredits = current.resetCredits
            merged.resetCreditsAvailable = current.resetCreditsAvailable
            if merged.plan == nil { merged.plan = current.plan }
            merged.windows += current.modelCaps
        }
        accept(merged, provider: .codex)
        scheduler.passiveCodexReading(at: reading.fetchedAt)
    }

    func save() async {
        let t0 = Date()
        defer { diag.notice("saved state \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s") }
        if firstScanDone { await saveIngest() }
        var state = PersistedState()
        state.history = history
        for p in Provider.allCases { if let g = faults[p]?.lastGood { state.lastGood[p.rawValue] = g } }
        state.claudeRefreshLastRun = await refresher.lastRunDate
        state.codexAccountKey = codexAccountKey
        try? store.save(state)
        Memory.relieve()
    }

    func flushOnQuit() async {
        await save()
    }

    // MARK: Scheduling

    private func tick() {
        let now = Date()
        for action in scheduler.due(at: now) {
            switch action {
            case .readLimits(let p): read(p)
            case .checkStatus(let p): checkStatus(p)
            }
        }
        armTimer()
    }

    private func armTimer() {
        let now = Date()
        guard let next = scheduler.nextDeadline(at: now) else { timer.cancel(); return }
        let delay = max(next.timeIntervalSince(now), 1)
        timer.arm(at: now.addingTimeInterval(delay), leeway: scheduler.leeway(forDelay: delay), now: now) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
    }

    func refreshNow() {
        scheduler.refreshNow()
        if settings.statusChecks { for p in settings.enabledProviders { checkStatus(p) } }
        tick()
        // Always rewrite the snapshot so `headroom --refresh` sees a new generated_at.
        lastSnapshotBody = nil
        writeSnapshot()
    }

    private func popoverOpened() {
        scheduler.popoverOpened(at: Date())
        if Self.overrideStamp() != pricingOverrideStamp {
            pricingOverrideStamp = Self.overrideStamp()
            pricing = PricingEngine.standard()
            let engine = pricing
            Task {
                await ingestor.reprice(Self.pricer(engine))
                buckets = await ingestor.buckets()
                changed()
            }
        }
        tick()
    }

    private func read(_ p: Provider) {
        guard !inFlight.contains(p), settings.enabledProviders.contains(p) else { return }
        // Codex: a fresh passive reading from the logs skips the spawn.
        if p == .codex, scheduler.codexPassiveIsFresh(at: Date()) {
            scheduler.recordLimitRead(p, at: Date(), succeeded: true, retryAt: nil)
            return
        }
        inFlight.insert(p)
        let popover = popoverOpen
        Task {
            let t0 = Date()
            let outcome: ProviderReadOutcome = p == .claude ? await claude.read(popoverOpen: popover) : await codex.read()
            diag.notice("read \(p.rawValue, privacy: .public) \(outcome.fault == nil ? "ok" : outcome.fault!.code, privacy: .public) \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
            inFlight.remove(p)
            let now = Date()
            var machine = faults[p] ?? FaultMachine(provider: p)
            machine.recordOutcome(outcome, at: now)
            faults[p] = machine
            if let reading = outcome.reading, outcome.fault == nil {
                if p == .codex { codexAccountKey = reading.accountKey }
                accept(reading, provider: p)
            } else if let reading = outcome.reading {
                history.record(reading, now: now) // text fallback still extends the glide
            }
            if outcome.fault != nil, settings.statusChecks { checkStatus(p) }
            scheduler.recordLimitRead(p, at: now, succeeded: outcome.fault == nil, retryAt: machine.nextRetryAt)
            changed()
            await saver?.schedule()
            armTimer()
        }
    }

    private func accept(_ reading: LimitReading, provider p: Provider) {
        var machine = faults[p] ?? FaultMachine(provider: p)
        if reading.source == .passiveLog { machine.recordSuccess(reading) } else if machine.lastGood != reading { machine.recordSuccess(reading) }
        faults[p] = machine
        history.record(reading, now: reading.fetchedAt)
        updateTracker(p, reading: reading)
    }

    private func updateTracker(_ p: Provider, reading: LimitReading) {
        guard let headline = reading.headline, headline.resetsAt != nil else { return }
        let key = HistoryStore.key(p, account: reading.accountKey)
        guard var acct = history.accounts[key] else { return }
        let samples = acct.windows[headline.id]?.samples ?? []
        let now = Date()
        let analysis = PacingEngine.analyze(window: headline, samples: samples, now: now)
        var tracker = acct.tracker ?? PacingTracker(policy: .standard)
        _ = tracker.update(analysis, now: now)
        acct.tracker = tracker
        history.accounts[key] = acct
    }

    private func checkStatus(_ p: Provider) {
        guard settings.statusChecks else { return }
        Task {
            let status = await statusClient.fetch(p)
            diag.notice("status \(p.rawValue, privacy: .public) \(status?.level.rawValue ?? -1)")
            scheduler.recordStatusCheck(p, at: Date())
            if let status { serviceStatus[p] = status }
            faults[p]?.applyStatus(status)
            changed()
            armTimer()
        }
    }

    private func pathChanged(_ satisfied: Bool) {
        guard satisfied else { return }
        let waiting = Set(Provider.allCases.filter { faults[$0]?.retryPolicy?.onPathSatisfied == true })
        scheduler.pathSatisfied(retrying: waiting)
        tick()
    }

    private func startObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.sleep(); self?.timer.cancel() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.wake(at: Date()); self?.tick() }
        })
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.screenLocked(); self?.armTimer() }
        })
        observers.append(dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.screenUnlocked(at: Date()); self?.tick() }
        })
    }

    // MARK: Change propagation

    private func changed() {
        onChange?()
        writeSnapshot()
        armMinuteTimer()
    }

    /// While a countdown is visible (session warning, blocked) or the popover is open, redraw once a minute.
    private func armMinuteTimer() {
        let needs = popoverOpen || menuBarHasCountdown()
        if needs, minuteTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange?()
                    self.writeSnapshot()
                    if !(self.popoverOpen || self.menuBarHasCountdown()) { self.minuteTimer?.invalidate(); self.minuteTimer = nil }
                }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            minuteTimer = t
        } else if !needs {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
    }

    private func menuBarHasCountdown() -> Bool {
        let p = Presenter(now: Date())
        return paceInputs().compactMap { p.menuBar($0)?.model }.contains { $0.session != nil || $0.blockedCountdown != nil }
    }

    // MARK: Presentation input

    func paceInput(_ p: Provider) -> PaceInput {
        let machine = faults[p]
        let reading = machine?.lastGood
        var input = PaceInput(provider: p, reading: reading)
        input.fault = machine?.fault
        if let reading {
            let acct = history.account(p, reading.accountKey)
            if let acct { input.samples = acct.windows.mapValues(\.samples) }
            input.smoothedState = acct?.tracker?.shown
            if let early = acct?.earlyResetAt, let start = reading.headline?.windowStart, early >= start { input.earlyResetAt = early }
            if let start = reading.headline?.windowStart {
                input.weekCostMicros = buckets.totals(p, from: start, to: Date()).micros
            }
        } else if input.fault == nil, !firstScanDone || inFlight.contains(p) {
            input.fault = nil
        }
        input.planMonthlyOverride = settings.planPriceOverride(p)
        return input
    }

    func paceInputs() -> [PaceInput] {
        Provider.allCases.filter { settings.enabledProviders.contains($0) }.map(paceInput)
    }

    var majorOutages: [Provider: String] {
        serviceStatus.compactMapValues { $0.level >= .majorOutage ? ($0.description ?? "Major outage") : nil }
    }

    /// Footer line: all good, or the outage.
    var footer: FooterModel {
        if let scan = scanProgress { return FooterModel(text: scan, status: .stale) }
        let outages = serviceStatus.filter { settings.enabledProviders.contains($0.key) && $0.value.isOutage }
        if let (p, s) = outages.sorted(by: { $0.key < $1.key }).first {
            return FooterModel(text: s.description ?? "\(p.displayName) outage", status: .error)
        }
        return FooterModel(text: "All systems normal", status: .fresh)
    }

    func aggregates() -> [HourAggregate] {
        buckets.allSlots.map { s in
            HourAggregate(provider: s.key.provider, hour: Date(timeIntervalSince1970: Double(s.key.slot) * Double(UsageBuckets.slotSeconds)),
                          model: s.model, project: s.project.isEmpty ? nil : s.project, tokens: s.totals.tokens,
                          micros: s.totals.micros, priced: s.totals.unpricedTokens == 0,
                          classMicros: ClassMicros(input: s.totals.cost.input, cacheWrite: s.totals.cost.cacheWrite,
                                                    cacheRead: s.totals.cost.cacheRead, output: s.totals.cost.output))
        }
    }

    var pricingEngine: PricingEngine { pricing }

    // MARK: Snapshot

    private func writeSnapshot() {
        let snapshot = SnapshotBuilder(now: Date()).build(model: self)
        var body = snapshot
        body.generatedAt = .distantPast
        let encoded = try? SnapshotFile.encoder().encode(body)
        if let encoded, encoded == lastSnapshotBody { return }
        lastSnapshotBody = encoded
        _ = try? snapshotWriter.write(snapshot)
    }
}
