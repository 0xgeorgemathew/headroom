import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--render") {
    let code = MainActor.assumeIsolated { RenderCommand.run(arguments) }
    exit(code)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
