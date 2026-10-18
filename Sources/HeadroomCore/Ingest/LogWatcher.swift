import CoreServices
import Foundation

/// FSEvents watcher over the log roots (PLAN §4: 3 s latency). Reports changed file paths;
/// `rescan` is true when FSEvents dropped events and a full scan is needed.
public final class LogWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ paths: [String], _ rescan: Bool) -> Void

    private let roots: [String]
    private let latency: CFTimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "headroom.logwatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(roots: [URL], latency: CFTimeInterval = 3, handler: @escaping Handler) {
        self.roots = roots.map(\.path)
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { stop() }

    /// Starts watching the roots that exist. Returns false when none could be watched.
    @discardableResult
    public func start() -> Bool {
        queue.sync {
            guard stream == nil else { return true }
            let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { return false }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let s = FSEventStreamCreate(
                kCFAllocatorDefault, LogWatcher.callback, &context, existing as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return false }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
            return true
        }
    }

    public func stop() {
        let stop = {
            if let s = self.stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                self.stream = nil
            }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stop() } else { queue.sync(execute: stop) }
    }

    private static let queueKey = DispatchSpecificKey<Void>()

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        var changed: [String] = []
        var rescan = false
        for i in 0..<count {
            let f = Int(flags[i])
            if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                rescan = true
            }
            if i < array.count {
                let p = array[i]
                if p.hasSuffix(".jsonl") || p.hasSuffix(".jsonl.zst") { changed.append(p) }
            }
        }
        if !changed.isEmpty || rescan { watcher.handler(changed, rescan) }
    }
}
