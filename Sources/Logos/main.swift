import AppKit

let arguments = CommandLine.arguments
if arguments.count > 2, arguments[1] == "--transcribe" {
    CLI.transcribe(Array(arguments.dropFirst(2)))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// `Logos --transcribe <file> [--app <name>] [--no-cleanup]` runs one audio file
/// through the same pipeline as a dictation and prints the result, without pasting.
/// Useful for trying out prompt and model changes.
enum CLI {
    static func transcribe(_ args: [String]) -> Never {
        let audio = URL(fileURLWithPath: args[0])
        let app = args.firstIndex(of: "--app").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "Terminal"

        ConfigStore.shared.ensureFiles()
        var config = ConfigStore.shared.current
        if let error = ConfigStore.shared.lastError { fputs("warning: \(error)\n", stderr) }
        if args.contains("--no-cleanup") { config.cleanup.enabled = false }
        config.saveHistory = false
        let prompt = ConfigStore.shared.prompt

        Task {
            let start = Date()
            do {
                let outcome = try await Pipeline.run(audio: audio, config: config, prompt: prompt, app: app) {
                    fputs("\($0)\n", stderr)
                }
                print("raw:   \(outcome.raw)")
                if config.cleanup.enabled { print("clean: \(outcome.text)") }
                if let warning = outcome.warning { fputs("warning: \(warning)\n", stderr) }
                fputs(String(format: "took %.2fs\n", Date().timeIntervalSince(start)), stderr)
                exit(0)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }
}
