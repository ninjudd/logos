import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if CLI.handles(arguments) {
    CLI.run(arguments)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
