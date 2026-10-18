import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--scan-logs", arguments.count == 3 {
    exit(ScanChild.run(input: arguments[1], output: arguments[2]))
}
if arguments.contains("--render") {
    let code = MainActor.assumeIsolated { RenderCommand.run(arguments) }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
