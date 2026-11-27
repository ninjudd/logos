import Foundation

/// The `logos` command. It's the app's own binary, linked onto your PATH by
/// install.sh, so the command and the app are always the same version.
enum CLI {
    enum Command: Equatable {
        case transcribe(file: String, app: String, cleanup: Bool)
        case update(check: Bool, force: Bool)
        case version
        case help
    }

    static let usage = """
    Usage: logos <command>

    Commands:
      transcribe <file> [--app <name>] [--no-cleanup]
                    Run an audio file through transcription and cleanup, as a
                    dictation would, and print the result instead of pasting it.
      update [--check] [--force]
                    Build and install the latest release. --check only reports
                    whether one is available; --force reinstalls it anyway.
      version       Print the installed version.
      help          Print this help.

    Settings live in ~/.config/logos. The menu bar app starts at login, or with
    `open -a Logos`.
    """

    /// Whether these arguments are a command rather than an app launch. macOS
    /// launches the app from inside Logos.app, with no arguments or with flags
    /// such as -NSDocumentRevisionsDebugMode, so anything else is meant for the
    /// CLI. Through the `logos` symlink, no arguments prints help, so the command
    /// never starts a second copy of the app.
    static func handles(_ args: [String], invokedAs path: String = CommandLine.arguments[0]) -> Bool {
        guard let first = args.first else { return !path.hasSuffix(".app/Contents/MacOS/Logos") }
        return !first.hasPrefix("-") || ["-h", "--help", "--version"].contains(first)
    }

    static func parse(_ args: [String]) throws -> Command {
        guard let name = args.first else { return .help }
        var rest = Array(args.dropFirst())
        func flag(_ flag: String) -> Bool {
            guard let i = rest.firstIndex(of: flag) else { return false }
            rest.remove(at: i)
            return true
        }
        func option(_ option: String) throws -> String? {
            guard let i = rest.firstIndex(of: option) else { return nil }
            guard i + 1 < rest.count else { throw LogosError("\(option) needs a value") }
            let value = rest[i + 1]
            rest.removeSubrange(i...i + 1)
            return value
        }
        func noneLeft() throws {
            if let extra = rest.first { throw LogosError("Unexpected argument \"\(extra)\" for \(name)") }
        }

        switch name {
        case "transcribe":
            let app = try option("--app") ?? "Terminal"
            let cleanup = !flag("--no-cleanup")
            guard !rest.isEmpty else { throw LogosError("transcribe needs an audio file") }
            let file = rest.removeFirst()
            try noneLeft()
            return .transcribe(file: file, app: app, cleanup: cleanup)
        case "update":
            let command = Command.update(check: flag("--check"), force: flag("--force"))
            try noneLeft()
            return command
        case "version", "--version":
            try noneLeft()
            return .version
        case "help", "-h", "--help":
            return .help
        default:
            throw LogosError("Unknown command \"\(name)\"")
        }
    }

    static func run(_ args: [String]) -> Never {
        let command: Command
        do {
            command = try parse(args)
        } catch {
            fputs("logos: \(error.localizedDescription)\n\n\(usage)\n", stderr)
            exit(2)
        }
        switch command {
        case .help:
            print(usage)
            exit(0)
        case .version:
            print("logos \(Updater.installedVersion)")
            exit(0)
        case .transcribe(let file, let app, let cleanup):
            runAsync { await transcribe(file: file, app: app, cleanup: cleanup) }
        case .update(let check, let force):
            runAsync { await update(check: check, force: force) }
        }
    }

    private static func runAsync(_ body: @escaping () async -> Int32) -> Never {
        Task { exit(await body()) }
        dispatchMain()
    }

    private static func transcribe(file: String, app: String, cleanup: Bool) async -> Int32 {
        ConfigStore.shared.ensureFiles()
        var config = ConfigStore.shared.current
        if let error = ConfigStore.shared.lastError { fputs("warning: \(error)\n", stderr) }
        if !cleanup { config.cleanup.enabled = false }
        config.saveHistory = false
        let newer = Task { await Updater.latestTagCached() }

        let start = Date()
        let status: Int32
        do {
            let outcome = try await Pipeline.run(audio: URL(fileURLWithPath: file), config: config,
                                                 prompt: ConfigStore.shared.prompt,
                                                 vocabulary: ConfigStore.shared.dictionary, app: app) {
                fputs("\($0)\n", stderr)
            }
            print("raw:   \(outcome.raw)")
            if config.cleanup.enabled { print("clean: \(outcome.text)") }
            if let warning = outcome.warning { fputs("warning: \(warning)\n", stderr) }
            fputs(String(format: "took %.2fs\n", Date().timeIntervalSince(start)), stderr)
            status = 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            status = 1
        }
        await warnIfBehind(newer)
        return status
    }

    /// Prints a warning when a newer release exists, giving the daily check two
    /// seconds at most so it never holds up a command.
    private static func warnIfBehind(_ check: Task<String?, Never>) async {
        let timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            check.cancel()
        }
        defer { timeout.cancel() }
        guard let tag = await check.value, Updater.isNewer(tag, than: Updater.installedVersion) else { return }
        fputs("warning: logos \(Updater.installedVersion) is behind the \(tag) release; run 'logos update'\n", stderr)
    }

    private static func update(check: Bool, force: Bool) async -> Int32 {
        do {
            let tag = try await Updater.latestTag()
            let current = Updater.installedVersion
            let newer = Updater.isNewer(tag, than: current)
            print("logos \(current) is installed; the latest release is \(tag)")
            if check { return newer ? 1 : 0 }
            guard newer || force else {
                print("logos is up to date")
                return 0
            }
            let installer = try await Updater.installer(tag: tag)
            defer { try? FileManager.default.removeItem(at: installer) }
            let process = Updater.installProcess(installer: installer, tag: tag)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("logos update: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
