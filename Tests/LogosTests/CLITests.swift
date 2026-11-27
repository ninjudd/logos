import Foundation
import Testing
@testable import Logos

@Suite struct CLITests {
    // Catches the app failing to start because macOS passed it a flag, or a typo'd
    // command starting a second copy of the app in the terminal.
    @Test func commandsAreForTheCLIAndFlagsAreForTheApp() {
        #expect(CLI.handles(["update"]))
        #expect(CLI.handles(["transcibe"]))
        #expect(CLI.handles(["--help"]))
        #expect(CLI.handles(["--version"]))
        #expect(!CLI.handles(["-NSDocumentRevisionsDebugMode", "YES"]))
    }

    // Catches the `logos` command starting a second copy of the app, which would
    // paste every dictation twice.
    @Test func noArgumentsStartTheAppOnlyFromInsideLogosApp() {
        #expect(!CLI.handles([], invokedAs: "/Applications/Logos.app/Contents/MacOS/Logos"))
        #expect(CLI.handles([], invokedAs: "/Users/me/.local/bin/logos"))
        #expect(CLI.handles([], invokedAs: "logos"))
    }

    @Test func transcribeTakesAFileAndOptions() throws {
        #expect(try CLI.parse(["transcribe", "a.wav"]) == .transcribe(file: "a.wav", app: "Terminal", cleanup: true))
        #expect(try CLI.parse(["transcribe", "--app", "Slack", "a.wav", "--no-cleanup"])
            == .transcribe(file: "a.wav", app: "Slack", cleanup: false))
    }

    @Test func transcribeWithoutAFileIsAnError() {
        #expect(throws: (any Error).self) { try CLI.parse(["transcribe", "--no-cleanup"]) }
        #expect(throws: (any Error).self) { try CLI.parse(["transcribe", "a.wav", "--app"]) }
    }

    @Test func updateFlags() throws {
        #expect(try CLI.parse(["update"]) == .update(check: false, force: false))
        #expect(try CLI.parse(["update", "--force", "--check"]) == .update(check: true, force: true))
    }

    // Catches a typo'd flag being ignored, such as `update --chek` installing an update.
    @Test func unknownArgumentsAreErrors() {
        #expect(throws: (any Error).self) { try CLI.parse(["update", "--chek"]) }
        #expect(throws: (any Error).self) { try CLI.parse(["version", "extra"]) }
        #expect(throws: (any Error).self) { try CLI.parse(["transcibe", "a.wav"]) }
    }

    @Test func helpAndVersion() throws {
        #expect(try CLI.parse([]) == .help)
        #expect(try CLI.parse(["help"]) == .help)
        #expect(try CLI.parse(["--help"]) == .help)
        #expect(try CLI.parse(["version"]) == .version)
        #expect(try CLI.parse(["--version"]) == .version)
    }
}

@Suite struct UpdaterTests {
    // Catches comparing versions as strings, where "0.10.0" sorts before "0.9.0".
    @Test func comparesVersionsNumerically() {
        #expect(Updater.isNewer("v0.10.0", than: "0.9.0"))
        #expect(!Updater.isNewer("0.9.0", than: "v0.10.0"))
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(!Updater.isNewer("v1.2.3", than: "1.2.3"))
        #expect(!Updater.isNewer("1.2", than: "1.2.0"))
    }

    @Test func eachPartCounts() {
        #expect(Updater.isNewer("2.0.0", than: "1.9.9"))
        #expect(Updater.isNewer("1.3.0", than: "1.2.9"))
        #expect(Updater.isNewer("1.2.4", than: "1.2.3"))
    }

    // Catches a version release.py can't bump, which would break the release workflow.
    @Test func infoPlistVersionIsMajorMinorPatch() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(version.wholeMatch(of: #/\d+\.\d+\.\d+/#) != nil)
        #expect(Int(try #require(info["CFBundleVersion"] as? String)) != nil)
    }
}
