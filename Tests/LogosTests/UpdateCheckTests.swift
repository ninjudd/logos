import Foundation
import Testing
@testable import Logos

@Suite struct UpdateCheckTests {
    private let cache = FileManager.default.temporaryDirectory
        .appending(path: "logos-release-\(UUID().uuidString)/release.json")

    private func removeCache() {
        try? FileManager.default.removeItem(at: cache.deletingLastPathComponent())
    }

    // Catches a config.json written before the setting existed, which lacks the
    // key, turning automatic checks off.
    @Test func checksForUpdatesByDefault() throws {
        #expect(Config().checkForUpdates)
        #expect(try Config.decode(Data("{}".utf8)).checkForUpdates)
        #expect(try !Config.decode(Data(#"{"checkForUpdates": false}"#.utf8)).checkForUpdates)
    }

    // Catches the automatic check ignoring the setting and asking GitHub anyway.
    @Test func automaticCheckAsksNothingWhenTurnedOff() async {
        var asked = false
        let tag = await Updater.automaticCheck(enabled: false, installed: "0.2.0") {
            asked = true
            return "v0.3.0"
        }
        #expect(tag == nil)
        #expect(!asked)
    }

    // Catches the automatic check offering the version you already have.
    @Test func automaticCheckOffersOnlyANewerRelease() async {
        #expect(await Updater.automaticCheck(enabled: true, installed: "0.2.0") { "v0.3.0" } == "v0.3.0")
        #expect(await Updater.automaticCheck(enabled: true, installed: "0.2.0") { "v0.2.0" } == nil)
        #expect(await Updater.automaticCheck(enabled: true, installed: "0.2.0") { nil } == nil)
    }

    // Catches Check for Updates… answering from a day-old cache, so it calls you
    // up to date while a newer release is out, and leaving that cache stale for
    // the automatic check.
    @Test func checkIgnoresAndRefreshesTheCache() async {
        defer { removeCache() }
        #expect(await Updater.latestTagCached(cache: cache, offline: false) { "v0.2.0" } == "v0.2.0")

        let result = await Updater.check(installed: "0.2.0", cache: cache) { "v0.3.0" }
        #expect(result == .newer("v0.3.0"))

        let cached = await Updater.latestTagCached(cache: cache, offline: false) {
            Issue.record("The cache should hold the manual check's answer")
            return "v0.0.0"
        }
        #expect(cached == "v0.3.0")
    }

    // Catches latestTagCached dropping its offline guard and asking GitHub
    // anyway. It passes offline itself, so it doesn't check that the default
    // reads LOGOS_OFFLINE.
    @Test func cachedCheckAsksNothingWhenOffline() async {
        defer { removeCache() }
        var asked = false
        let tag = await Updater.latestTagCached(cache: cache, offline: true) {
            asked = true
            return "v0.3.0"
        }
        #expect(tag == nil)
        #expect(!asked)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func checkReportsTheLatestVersionWhenUpToDate() async {
        defer { removeCache() }
        #expect(await Updater.check(installed: "0.3.0", cache: cache) { "v0.3.0" } == .upToDate(latest: "v0.3.0"))
    }

    // Catches a failed check showing nothing, or caching a tag it never got.
    @Test func checkReportsTheError() async {
        defer { removeCache() }
        let result = await Updater.check(installed: "0.2.0", cache: cache) { throw LogosError("GitHub is down") }
        #expect(result == .failed("GitHub is down"))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    // Catches a check just after a release repeating the answer an earlier check
    // got, which GitHub's Cache-Control header lets the URL cache keep for 60
    // seconds. A local server stands in for GitHub and names a newer release
    // each time it's asked.
    @Test func checkAsksGitHubAgainWithinAMinute() async throws {
        let server = try LocalHTTPServer { request in
            (["Cache-Control": "public, max-age=60, s-maxage=60"], #"{"tag_name": "v0.\#(request).0"}"#)
        }
        try await server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        #expect(try await Updater.latestTag(session: session, api: server.url) == "v0.1.0")
        #expect(try await Updater.latestTag(session: session, api: server.url) == "v0.2.0")
        #expect(server.requests == 2)
    }
}
