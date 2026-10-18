import Foundation
import HeadroomKit

public enum CLITool: String, Sendable, Hashable, CaseIterable {
    case claude
    case codex
}

/// Finds the `claude` and `codex` executables (PLAN §5.5): a user override first, then the login
/// shell's `command -v`, then the usual install locations.
public struct CLILocator: Sendable {
    let runner: any ProcessRunning
    let home: String
    let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        home: String = NSHomeDirectory(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.home = home
        self.isExecutable = isExecutable
    }

    public func knownDirectories() -> [String] {
        [home + "/.local/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin"]
    }

    public func locate(_ tool: CLITool, override: String? = nil) async -> String? {
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let expanded = override.hasPrefix("~") ? home + override.dropFirst() : override
            return isExecutable(expanded) ? expanded : nil
        }
        // `tool.rawValue` is a fixed identifier, never user input.
        if let result = try? await runner.run("/bin/zsh", arguments: ["-lc", "command -v \(tool.rawValue)"],
                                              currentDirectory: nil, timeout: 5),
           result.status == 0
        {
            let path = String(decoding: result.stdout, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if path.hasPrefix("/"), isExecutable(path) { return path }
        }
        for dir in knownDirectories() {
            let candidate = dir + "/" + tool.rawValue
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

/// Caches resolved paths for an hour, and until the user changes an override (PLAN §5.5).
public actor CLIResolver {
    public static let ttl: TimeInterval = 3600

    let locator: CLILocator
    let clock: any ProviderClock
    private var overrides: [CLITool: String] = [:]
    private var cache: [CLITool: (path: String?, at: Date)] = [:]

    public init(locator: CLILocator = CLILocator(), clock: any ProviderClock = SystemClock()) {
        self.locator = locator
        self.clock = clock
    }

    public func setOverride(_ path: String?, for tool: CLITool) {
        overrides[tool] = path
        cache[tool] = nil
    }

    public func invalidate() { cache.removeAll() }

    public func path(for tool: CLITool) async -> String? {
        if let hit = cache[tool], clock.now.timeIntervalSince(hit.at) < Self.ttl { return hit.path }
        let path = await locator.locate(tool, override: overrides[tool])
        cache[tool] = (path, clock.now)
        return path
    }
}
