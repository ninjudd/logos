import Foundation
import Testing
@testable import Logos

@Suite struct UpdateProgressTests {
    @Test func progressFollowsTheInstallerLog() {
        #expect(Updater.progress(log: "") == "downloading")
        #expect(Updater.progress(log: "Downloading Logos v0.1.3 from ninjudd/logos\n") == "downloading")
        #expect(Updater.progress(log: "Downloading Logos v0.1.3\nBuilding for production...\n[Planning deferred tasks]\n") == "building")
        #expect(Updater.progress(log: "Building for production...\n[16 / 21]\n[17 / 22] Logos-product\n[59 / 100]\n") == "building 59%")
        #expect(Updater.progress(log: "[99 / 100] Logos-product\nBuild complete! (10.25 sec)\nBuilt build/Logos.app (signed)\n") == "installing")
    }

    // Catches a finished step count reading as done before the app is installed.
    @Test func progressStopsShortOfAHundredWhileBuilding() {
        #expect(Updater.progress(log: "[100 / 100] Logos-product\n") == "building 99%")
    }

    @Test func launchSaysTheUpdateWorked() {
        let message = Updater.launchMessage(after: .init(from: "0.1.2", to: "v0.1.3"), installed: "0.1.3")
        #expect(message.text == "Updated to Logos 0.1.3")
        #expect(message.success)
    }

    // Catches an update that left the old version running being reported as done.
    @Test func launchSaysTheUpdateDidntFinish() {
        let message = Updater.launchMessage(after: .init(from: "0.1.2", to: "v0.1.3"), installed: "0.1.2")
        #expect(message.text.hasPrefix("The update to Logos 0.1.3 didn't finish, so this is still 0.1.2."))
        #expect(!message.success)
    }

    // Catches the update's news repeating on every later launch.
    @Test func pendingUpdateIsReportedOnce() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "logos-pending-\(UUID().uuidString)/update.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(Updater.takePending(at: file) == nil)
        Updater.recordPending(.init(from: "0.1.2", to: "v0.1.3"), at: file)
        #expect(Updater.takePending(at: file) == .init(from: "0.1.2", to: "v0.1.3"))
        #expect(Updater.takePending(at: file) == nil)
    }
}
