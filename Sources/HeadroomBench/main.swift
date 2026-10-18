import Foundation
import HeadroomCore
import HeadroomKit

// Dev and benchmark tool (PLAN §4.4, §11 lane 1c). Read-only toward ~/.claude and ~/.codex;
// the incremental benchmark writes only into a temporary directory.
//
//   HeadroomBench scan [--cutoff EPOCH] [--parallel N] [--quiet]
//   HeadroomBench incremental
//   HeadroomBench zstd-check [N]

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "scan"

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func wallClock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let noPrice: EventPricer = { _ in .unpriced }

switch command {
case "reads":
    // Live read-only probe of memory per step: Keychain read, usage API, Codex app-server, status pages.
    func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    let n = Int(option("--count") ?? "3") ?? 3
    print(String(format: "start %.1f MB", footprintMB()))
    let resolver = CLIResolver()
    let claude = ClaudeUsageClient(refresher: nil)
    let codex = CodexAppServerClient { await resolver.path(for: .codex) }
    let status = StatusClient()
    for i in 0..<n {
        _ = try? await ClaudeCredentialReader().read()
        print(String(format: "[%d] keychain %.1f MB", i, footprintMB()))
        let c = await claude.read()
        print(String(format: "[%d] claude %@ %.1f MB", i, c.fault == nil ? "ok" : "fault", footprintMB()))
        let x = await codex.read()
        print(String(format: "[%d] codex %@ %.1f MB", i, x.fault == nil ? "ok" : "fault", footprintMB()))
        _ = await status.fetch(.claude)
        print(String(format: "[%d] status %.1f MB", i, footprintMB()))
    }
case "scan":
    let cutoff = option("--cutoff").flatMap(Double.init) ?? (Date().timeIntervalSince1970 - 35 * 86400)
    let parallel = option("--parallel").flatMap(Int.init) ?? 4
    let fixedNow = Date(timeIntervalSince1970: cutoff + 35 * 86400)
    let home = option("--home").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    let ingestor = LogIngestor(roots: .standard(home: home), pricer: noPrice, parallelism: parallel, now: { fixedNow })
    let t0 = wallClock()
    let report = await ingestor.scanAll()
    let elapsed = wallClock() - t0
    let buckets = await ingestor.buckets()
    var rows: [String: [Int64]] = [:]
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.locale = Locale(identifier: "en_US_POSIX")
    for s in buckets.allSlots {
        let day = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(Int(s.key.slot) * UsageBuckets.slotSeconds)))
        let key = "\(s.key.provider.rawValue) \(s.model) \(day)"
        let t = s.totals.tokens
        let add: [Int64] = [t.newInput, t.cacheWrite5m, t.cacheWrite1h, t.cacheRead, t.output, Int64(s.totals.events)]
        rows[key] = zip(rows[key] ?? [0, 0, 0, 0, 0, 0], add).map { $0 + $1 }
    }
    if !args.contains("--quiet") {
        for key in rows.keys.sorted() { print(key, rows[key]!.map(String.init).joined(separator: " ")) }
    }
    var grand: [String: [Int64]] = [:]
    for (key, row) in rows {
        let p = String(key.split(separator: " ")[0])
        grand[p] = zip(grand[p] ?? [0, 0, 0, 0, 0, 0], row).map { $0 + $1 }
    }
    for p in grand.keys.sorted() { stderr("TOTAL \(p) " + grand[p]!.map(String.init).joined(separator: " ")) }
    let mb = Double(report.bytesProcessed) / 1e6
    stderr(String(format: "first-scan %.3fs parallel=%d files visited=%d read=%d processed=%.0f MB events=%d errors=%d",
                  elapsed, parallel, report.filesVisited, report.filesRead, mb, await ingestor.eventCount, report.errors.count))
    for e in report.errors.prefix(5) { stderr("  error: \(e)") }
    let state = await ingestor.exportState()
    let encoded = try PropertyListEncoder().encode(state)
    stderr("state.plist size: \(encoded.count / 1024) KB, cursors=\(state.cursors.count)")

case "incremental":
    // Appends real Claude log bytes to a temp copy and times ingest(paths:) per appended MB.
    let home = FileManager.default.homeDirectoryForCurrentUser
    var sources: [URL] = []
    if let e = FileManager.default.enumerator(at: home.appendingPathComponent(".claude/projects"), includingPropertiesForKeys: [.fileSizeKey]) {
        for case let u as URL in e.allObjects where u.pathExtension == "jsonl" { sources.append(u) }
    }
    sources.sort { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    guard let big = sources.first else { print("no Claude logs"); exit(1) }
    let source = try Data(contentsOf: big)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-bench-\(getpid())")
    let project = tmp.appendingPathComponent("claude/p")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let file = project.appendingPathComponent("s.jsonl")
    // Split at a newline near the middle.
    var cut = source.count / 2
    while cut < source.count && source[cut] != 0x0A { cut += 1 }
    try source.prefix(cut + 1).write(to: file)
    let roots = LogRoots(claude: [tmp.appendingPathComponent("claude")], codex: [tmp.appendingPathComponent("codex")])
    let ingestor = LogIngestor(roots: roots, pricer: noPrice)
    _ = await ingestor.scanAll()
    let appended = source.suffix(from: cut + 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: appended)
    try handle.close()
    let t0 = wallClock()
    let r = await ingestor.ingest(paths: [file.path])
    let ms = (wallClock() - t0) * 1000
    let mb = Double(r.bytesProcessed) / 1e6
    print(String(format: "incremental: %.1f MB appended, %.2f ms, %.2f ms/MB, events=%d", mb, ms, ms / max(mb, 0.001), r.eventsAdded))

case "zstd-check":
    // Decode N real rollouts and compare against `zstd -dc` byte for byte.
    let limit = args.count > 1 ? Int(args[1]) ?? 20 : 20
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    var files: [URL] = []
    if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let url as URL in e.allObjects where url.path.hasSuffix(".jsonl.zst") { files.append(url) }
    }
    files.sort { $0.path > $1.path }
    var ok = 0, bad = 0, inBytes = 0, outBytes = 0, seconds = 0.0
    for url in files.prefix(limit) {
        let data = try Data(contentsOf: url)
        let t0 = wallClock()
        let mine = try Zstd.decompress(data)
        seconds += wallClock() - t0
        inBytes += data.count
        outBytes += mine.count
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
        p.arguments = ["-dc", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let ref = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if ref == mine { ok += 1 } else { bad += 1; print("MISMATCH", url.lastPathComponent, ref.count, mine.count) }
    }
    print("zstd-check files=\(ok + bad) ok=\(ok) bad=\(bad) in=\(inBytes) out=\(outBytes) decode=\(String(format: "%.3f", seconds))s throughput=\(String(format: "%.0f", Double(outBytes) / seconds / 1e6)) MB/s")

default:
    print("usage: HeadroomBench [scan [--cutoff EPOCH] [--parallel N] [--quiet] | incremental | zstd-check [N]]")
}
