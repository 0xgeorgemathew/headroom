import Foundation
import HeadroomCore
import HeadroomKit

/// Full log scans run in a short-lived child process (`HeadroomApp --scan-logs in out`). Parsing
/// gigabytes of JSONL leaves a fragmented heap and a ~600 MB peak; doing it in a child keeps the
/// resident app near its idle budget. The child reads only local logs and writes only `out`.
enum ScanChild {
    /// Child side. Returns the exit status.
    static func run(input: String, output: String) -> Int32 {
        let state = PlistStore<IngestState>(url: URL(fileURLWithPath: input)).load()
        let engine = PricingEngine.standard()
        let pricer: EventPricer = { event in
            let c = engine.price(event)
            return EventPrice(cost: ClassCost(input: c.input, cacheWrite: c.cacheWrite, cacheRead: c.cacheRead, output: c.output), priced: c.priced)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32 = 1
        Task.detached(priority: .utility) {
            let ingestor = LogIngestor(pricer: pricer, state: state)
            _ = await ingestor.scanAll()
            let exported = await ingestor.exportState()
            do {
                try PlistStore<IngestState>(url: URL(fileURLWithPath: output)).save(exported)
                status = 0
            } catch {
                status = 1
            }
            done.signal()
        }
        done.wait()
        return status
    }

    /// Parent side: hands the current state to a child, waits, and returns the scanned state.
    static func scan(current: IngestState) async -> IngestState? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let dir = PlistStore<IngestState>.standardDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent(".scan-in.plist"), output = dir.appendingPathComponent(".scan-out.plist")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        do { try PlistStore<IngestState>(url: input).save(current) } catch { return nil }
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--scan-logs", input.path, output.path]
        process.qualityOfService = .utility
        let ok: Bool = await withCheckedContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus == 0) }
            do { try process.run() } catch { cont.resume(returning: false) }
        }
        guard ok else { return nil }
        return PlistStore<IngestState>(url: output).load()
    }
}
