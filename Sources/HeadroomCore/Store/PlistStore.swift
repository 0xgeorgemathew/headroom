import Foundation

/// Atomic binary-plist persistence for one Codable value (PLAN §4.2: `state.plist`).
public struct PlistStore<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Headroom/<name>`.
    public static func standardDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Headroom", isDirectory: true)
    }

    public static func standard(named name: String = "state.plist") -> PlistStore<Value> {
        PlistStore(url: standardDirectory().appendingPathComponent(name))
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

/// Coalesces saves: the first `schedule()` arms a timer; `flush()` saves immediately (on quit).
public actor DebouncedSaver {
    private let delay: Duration
    private let save: @Sendable () async -> Void
    private var pending: Task<Void, Never>?

    public init(delay: Duration = .seconds(300), save: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.save = save
    }

    public func schedule() {
        guard pending == nil else { return }
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    public func flush() async {
        pending?.cancel()
        pending = nil
        await save()
    }

    public var isPending: Bool { pending != nil }

    private func fire() async {
        pending = nil
        await save()
    }
}
