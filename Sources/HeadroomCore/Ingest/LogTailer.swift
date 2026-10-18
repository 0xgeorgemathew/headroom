import Darwin
import Foundation
import HeadroomKit

/// Where the local logs live. Injectable for tests.
public struct LogRoots: Sendable, Hashable {
    public var claude: [URL]
    public var codex: [URL]

    public init(claude: [URL], codex: [URL]) {
        self.claude = claude
        self.codex = codex
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LogRoots {
        LogRoots(
            claude: [home.appendingPathComponent(".claude/projects")],
            codex: [home.appendingPathComponent(".codex/sessions"), home.appendingPathComponent(".codex/archived_sessions")]
        )
    }

    func provider(for path: String) -> Provider? {
        if claude.contains(where: { path.hasPrefix($0.path + "/") }) { return .claude }
        if codex.contains(where: { path.hasPrefix($0.path + "/") }) { return .codex }
        return nil
    }

    var all: [URL] { claude + codex }
}

/// Read position in one log file (PLAN §4.2). Keyed by the file's logical path:
/// its path without `.zst`, so a rollout compressed after it was tailed resumes in place.
public struct FileCursor: Codable, Sendable, Hashable {
    public var device: Int64
    public var inode: UInt64
    public var size: Int64
    /// Bytes consumed, in decoded bytes for `.zst` files. Always at a line boundary.
    public var offset: Int64
    public var mtime: Double
    public var compressed: Bool
    public var codex: CodexFileState?

    public init(device: Int64, inode: UInt64, size: Int64, offset: Int64, mtime: Double, compressed: Bool, codex: CodexFileState? = nil) {
        self.device = device
        self.inode = inode
        self.size = size
        self.offset = offset
        self.mtime = mtime
        self.compressed = compressed
        self.codex = codex
    }
}

/// What a scan did, for logs, the footer progress and the bench.
public struct ScanReport: Sendable {
    public var filesVisited = 0
    public var filesRead = 0
    /// Bytes read from disk plus bytes decoded from `.zst`.
    public var bytesProcessed: Int64 = 0
    public var eventsAdded = 0
    public var seconds: Double = 0
    public var errors: [String] = []

    public init() {}
}

/// Result of reading one file, produced off the actor and merged serially.
struct FileResult: Sendable {
    enum Item: Sendable {
        case add(UsageEvent)
        case retract([String])
        case limits(PassiveCodexLimits)
    }

    var logical: String
    var cursor: FileCursor
    var items: [Item] = []
    var bytes: Int64 = 0
    var error: String?
}

/// Pure file-reading logic. Nonisolated so the first scan can run files in parallel.
enum LogFileReader {
    struct Stat {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var mtime: Double
    }

    static func fileStat(_ path: String) -> Stat? {
        var st = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &st, 0) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return Stat(device: Int64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size), mtime: mtime)
    }

    static func logicalPath(_ path: String) -> String {
        path.hasSuffix(".zst") ? String(path.dropLast(4)) : path
    }

    /// Reads whatever is new in `path` since `cursor`. Returns nil when there is nothing to do.
    static func read(path: String, provider: Provider, cursor: FileCursor?) -> FileResult? {
        guard let st = fileStat(path) else { return nil }
        let compressed = path.hasSuffix(".zst")
        let logical = logicalPath(path)

        if compressed {
            // Immutable: done once its decoded bytes are consumed.
            if let c = cursor, c.compressed, c.device == st.device, c.inode == st.inode, c.size == st.size { return nil }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return FileResult(logical: logical, cursor: cursor ?? emptyCursor(st, compressed: true), error: "unreadable: \(path)")
            }
            let decoded: Data
            do {
                decoded = try Zstd.decompress(data)
            } catch {
                var c = cursor ?? emptyCursor(st, compressed: true)
                (c.device, c.inode, c.size, c.mtime, c.compressed) = (st.device, st.inode, st.size, st.mtime, true)
                return FileResult(logical: logical, cursor: c, bytes: Int64(data.count), error: "zstd \(error): \(path)")
            }
            // Resume where the plain file left off when it was tailed before compression.
            var start: Int64 = 0
            var codexState = CodexFileState()
            if let c = cursor, !c.compressed, c.offset <= Int64(decoded.count) {
                start = c.offset
                codexState = c.codex ?? CodexFileState()
            }
            var result = FileResult(logical: logical, cursor: FileCursor(
                device: st.device, inode: st.inode, size: st.size, offset: Int64(decoded.count),
                mtime: st.mtime, compressed: true, codex: provider == .codex ? codexState : nil))
            decoded.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                scan(base, from: Int(start), to: raw.count, final: true, provider: provider,
                     logical: logical, codex: &codexState, into: &result.items)
            }
            result.cursor.codex = provider == .codex ? codexState : nil
            result.bytes = Int64(decoded.count) - start + Int64(data.count)
            return result
        }

        var start: Int64 = 0
        var codexState = CodexFileState()
        if let c = cursor, !c.compressed, c.device == st.device, c.inode == st.inode, c.offset <= st.size {
            if c.size == st.size && c.offset == st.size { return nil }
            start = c.offset
            codexState = c.codex ?? CodexFileState()
        }
        guard st.size > start else {
            return FileResult(logical: logical, cursor: FileCursor(
                device: st.device, inode: st.inode, size: st.size, offset: start, mtime: st.mtime,
                compressed: false, codex: provider == .codex ? codexState : nil))
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return FileResult(logical: logical, cursor: cursor ?? emptyCursor(st, compressed: false), error: "open: \(path)") }
        defer { close(fd) }
        let length = Int(st.size)
        guard let map = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else {
            return FileResult(logical: logical, cursor: cursor ?? emptyCursor(st, compressed: false), error: "mmap: \(path)")
        }
        defer { munmap(map, length) }
        // Ask for read-ahead over the new region: cold first scans are I/O bound.
        let pageStart = Int(start) & ~(Int(getpagesize()) - 1)
        madvise(map + pageStart, length - pageStart, MADV_SEQUENTIAL)
        madvise(map + pageStart, length - pageStart, MADV_WILLNEED)
        let base = UnsafePointer<UInt8>(map.assumingMemoryBound(to: UInt8.self))
        // Never consume a trailing partial line.
        var end = length
        while end > Int(start) && base[end - 1] != 0x0A { end -= 1 }
        var result = FileResult(logical: logical, cursor: FileCursor(
            device: st.device, inode: st.inode, size: st.size, offset: Int64(end), mtime: st.mtime,
            compressed: false, codex: nil))
        scan(base, from: Int(start), to: end, final: false, provider: provider, logical: logical,
             codex: &codexState, into: &result.items)
        result.cursor.codex = provider == .codex ? codexState : nil
        result.bytes = Int64(end) - start
        return result
    }

    static func emptyCursor(_ st: Stat, compressed: Bool) -> FileCursor {
        FileCursor(device: st.device, inode: st.inode, size: st.size, offset: 0, mtime: st.mtime, compressed: compressed)
    }

    static func scan(_ base: UnsafePointer<UInt8>, from: Int, to: Int, final: Bool, provider: Provider,
                     logical: String, codex: inout CodexFileState, into items: inout [FileResult.Item]) {
        switch provider {
        case .claude: scanClaude(base, from: from, to: to, logical: logical, into: &items)
        case .codex: scanCodex(base, from: from, to: to, logical: logical, state: &codex, into: &items)
        }
    }

    /// Jumps between `"usage":{` occurrences instead of walking every line, so the large
    /// tool-result lines are skipped by memmem.
    static func scanClaude(_ base: UnsafePointer<UInt8>, from: Int, to: Int, logical: String, into items: inout [FileResult.Item]) {
        let needle: StaticString = "\"usage\":{"
        var pos = from
        while pos < to {
            guard let hit = memmem(base + pos, to - pos, needle.utf8Start, needle.utf8CodeUnitCount) else { break }
            let at = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - base
            var lineStart = at
            while lineStart > pos && base[lineStart - 1] != 0x0A { lineStart -= 1 }
            var lineEnd = to
            if let nl = memchr(base + at, 0x0A, to - at) {
                lineEnd = UnsafePointer<UInt8>(nl.assumingMemoryBound(to: UInt8.self)) - base
            }
            let start = lineStart
            if let event = ClaudeLogParser.parse(base + start, lineEnd - start, fallbackKey: "@\(logical):\(start)") {
                items.append(.add(event))
            }
            pos = lineEnd + 1
        }
    }

    static func scanCodex(_ base: UnsafePointer<UInt8>, from: Int, to: Int, logical: String,
                          state: inout CodexFileState, into items: inout [FileResult.Item]) {
        var pos = from
        while pos < to {
            var lineEnd = to
            if let nl = memchr(base + pos, 0x0A, to - pos) {
                lineEnd = UnsafePointer<UInt8>(nl.assumingMemoryBound(to: UInt8.self)) - base
            }
            if lineEnd > pos {
                switch CodexLogParser.parse(base + pos, lineEnd - pos, state: &state, fileKey: logical) {
                case .none: break
                case .event(let e): items.append(.add(e))
                case .eventRetracting(let e, let keys):
                    items.append(.retract(keys))
                    items.append(.add(e))
                case .limits(let l): items.append(.limits(l))
                case .legacy(let e, let l):
                    if let e { items.append(.add(e)) }
                    if let l { items.append(.limits(l)) }
                }
            }
            pos = lineEnd + 1
        }
    }
}

/// Persisted ingestion state: cursors, the event ledger and passive Codex limits.
public struct IngestState: Codable, Sendable {
    public var version = 1
    public var cursors: [String: FileCursor] = [:]
    public var models: [String] = []
    public var projects: [String] = []
    public var files: [String] = []
    /// Fixed-size binary ledger records (see `LedgerCodec`).
    public var ledger = Data()
    public var passiveLatest: PassiveCodexLimits?
    public var passiveTrusted: PassiveCodexLimits?

    public init() {}
}

/// The ingestion actor (PLAN §4): tails Claude and Codex logs, dedupes, prices and buckets usage.
public actor LogIngestor {
    public let roots: LogRoots
    private var pricer: EventPricer
    private let retention: TimeInterval
    private let parallelism: Int
    private let now: @Sendable () -> Date

    private var cursors: [String: FileCursor] = [:]
    private var ledger = UsageLedger()
    private var passiveLatest: PassiveCodexLimits?
    private var passiveTrusted: PassiveCodexLimits?
    private(set) var changeCount = 0

    public init(
        roots: LogRoots = .standard(),
        pricer: @escaping EventPricer,
        retention: TimeInterval = 35 * 86400,
        parallelism: Int = 4,
        state: IngestState? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.roots = roots
        self.pricer = pricer
        self.retention = retention
        self.parallelism = max(parallelism, 1)
        self.now = now
        if let state, state.version == 1 {
            cursors = state.cursors
            ledger = UsageLedger(entries: LedgerCodec.decode(state.ledger), models: state.models,
                                 projects: state.projects, files: state.files)
            passiveLatest = state.passiveLatest
            passiveTrusted = state.passiveTrusted
        }
    }

    // MARK: Queries

    public func buckets() -> UsageBuckets { ledger.buckets }

    /// Latest passive Codex limits. Trusted readings come only from `openai`-provider sessions.
    public func passiveLimits(trustedOnly: Bool = true) -> PassiveCodexLimits? {
        trustedOnly ? passiveTrusted : passiveLatest
    }

    public var eventCount: Int { ledger.entries.count }

    /// Monotonic counter bumped whenever usage or limits change; cheap change detection for callers.
    public var revision: Int { changeCount }

    public func exportState() -> IngestState {
        var s = IngestState()
        s.cursors = cursors
        s.models = ledger.buckets.models
        s.projects = ledger.buckets.projects
        s.files = ledger.files
        s.ledger = LedgerCodec.encode(Array(ledger.entries.values))
        s.passiveLatest = passiveLatest
        s.passiveTrusted = passiveTrusted
        return s
    }

    public func reprice(_ pricer: @escaping EventPricer) {
        self.pricer = pricer
        ledger.reprice(pricer)
        changeCount += 1
    }

    // MARK: Scanning

    /// Visits every log under the roots. Files never seen before are read only when modified within
    /// the retention window; known files are tailed from their cursor.
    public func scanAll() async -> ScanReport {
        let t0 = Date()
        let cutoff = now().addingTimeInterval(-retention).timeIntervalSince1970
        var candidates: [(path: String, provider: Provider)] = []
        for (provider, urls) in [(Provider.claude, roots.claude), (Provider.codex, roots.codex)] {
            for root in urls { candidates += Self.enumerate(root, provider: provider) }
        }
        let plain = Set(candidates.lazy.filter { !$0.path.hasSuffix(".zst") }.map(\.path))
        var work: [(path: String, provider: Provider, cursor: FileCursor?)] = []
        for c in candidates {
            // While both forms exist (mid-compression), the plain file is authoritative.
            if c.path.hasSuffix(".zst"), plain.contains(LogFileReader.logicalPath(c.path)) { continue }
            let logical = LogFileReader.logicalPath(c.path)
            let cursor = cursors[logical]
            if cursor == nil {
                guard let st = LogFileReader.fileStat(c.path), st.mtime >= cutoff else { continue }
            }
            work.append((c.path, c.provider, cursor))
        }
        var report = await run(work)
        report.filesVisited = candidates.count
        // Forget cursors of logs that no longer exist in either form.
        let present = Set(candidates.map { LogFileReader.logicalPath($0.path) })
        cursors = cursors.filter { present.contains($0.key) }
        ledger.prune(before: now().addingTimeInterval(-retention))
        report.seconds = Date().timeIntervalSince(t0)
        return report
    }

    /// Tails specific files (from FSEvents). Unknown paths outside the roots are ignored.
    public func ingest(paths: [String]) async -> ScanReport {
        let t0 = Date()
        var work: [(path: String, provider: Provider, cursor: FileCursor?)] = []
        var seen = Set<String>()
        for path in paths where path.hasSuffix(".jsonl") || path.hasSuffix(".jsonl.zst") {
            guard let provider = roots.provider(for: path), seen.insert(path).inserted else { continue }
            if path.hasSuffix(".zst"), FileManager.default.fileExists(atPath: LogFileReader.logicalPath(path)) { continue }
            work.append((path, provider, cursors[LogFileReader.logicalPath(path)]))
        }
        var report = await run(work)
        report.filesVisited = work.count
        report.seconds = Date().timeIntervalSince(t0)
        return report
    }

    private func run(_ work: [(path: String, provider: Provider, cursor: FileCursor?)]) async -> ScanReport {
        var report = ScanReport()
        guard !work.isEmpty else { return report }
        // Files never read before (the expensive ones) start first; order is otherwise by path.
        let ordered = work.sorted { ($0.cursor == nil ? 0 : 1, $0.path) < ($1.cursor == nil ? 0 : 1, $1.path) }
        var results: [FileResult] = []
        results.reserveCapacity(ordered.count)
        await withTaskGroup(of: FileResult?.self) { group in
            var next = 0
            let limit = min(parallelism, ordered.count)
            for _ in 0..<limit {
                let w = ordered[next]
                next += 1
                group.addTask(priority: .utility) { LogFileReader.read(path: w.path, provider: w.provider, cursor: w.cursor) }
            }
            for await r in group {
                if let r { results.append(r) }
                if next < ordered.count {
                    let w = ordered[next]
                    next += 1
                    group.addTask(priority: .utility) { LogFileReader.read(path: w.path, provider: w.provider, cursor: w.cursor) }
                }
            }
        }
        results.sort { $0.logical < $1.logical }
        for r in results {
            merge(r, into: &report)
        }
        return report
    }

    private func merge(_ r: FileResult, into report: inout ScanReport) {
        cursors[r.logical] = r.cursor
        report.filesRead += 1
        report.bytesProcessed += r.bytes
        if let e = r.error { report.errors.append(e) }
        var changed = false
        for item in r.items {
            switch item {
            case .add(let event):
                if ledger.add(event, file: r.logical, price: pricer(event)) {
                    report.eventsAdded += 1
                    changed = true
                }
            case .retract(let keys):
                ledger.retract(keys: keys)
                changed = true
            case .limits(let l):
                if passiveLatest == nil || l.timestamp >= passiveLatest!.timestamp {
                    passiveLatest = l
                    changed = true
                }
                if l.providerIsOpenAI, passiveTrusted == nil || l.timestamp >= passiveTrusted!.timestamp {
                    passiveTrusted = l
                }
            }
        }
        if changed { changeCount += 1 }
    }

    static func enumerate(_ root: URL, provider: Provider) -> [(path: String, provider: Provider)] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(String, Provider)] = []
        for case let url as URL in e {
            let p = url.path
            if p.hasSuffix(".jsonl") || (provider == .codex && p.hasSuffix(".jsonl.zst")) { out.append((p, provider)) }
        }
        return out
    }
}
