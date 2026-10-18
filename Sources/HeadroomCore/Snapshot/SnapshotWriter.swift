import Foundation
import HeadroomKit
import notify

/// Writes `snapshot.json` atomically (temp file + rename) so readers never see a partial file.
public struct SnapshotWriter: Sendable {
    public var url: URL

    public init(url: URL = SnapshotFile.url) { self.url = url }

    /// Returns the encoded size in bytes.
    @discardableResult
    public func write(_ snapshot: Snapshot) throws -> Int {
        let data = try SnapshotFile.encoder().encode(snapshot)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".snapshot.\(getpid()).tmp")
        try data.write(to: tmp, options: [])
        chmod(tmp.path, 0o644)
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return data.count
    }
}

/// Listens for `com.headroom.refresh` (posted by `headroom --refresh`).
public final class RefreshObserver: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private var token: Int32 = 0
    private var registered = false

    public init(queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let status = notify_register_dispatch(SnapshotFile.refreshNotification, &token, queue) { [handler] _ in handler() }
        registered = status == UInt32(NOTIFY_STATUS_OK)
    }

    deinit {
        if registered { notify_cancel(token) }
    }
}
