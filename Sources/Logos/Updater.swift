import Foundation

/// Finds the newest Logos release on GitHub and installs it by running that
/// release's own install.sh, which builds it from source on this Mac.
enum Updater {
    static var repo: String { ProcessInfo.processInfo.environment["LOGOS_REPO"] ?? "ninjudd/logos" }

    static var installedVersion: String {
        appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Logos.app, also when the binary runs through the `logos` symlink, which
    /// makes Bundle.main look for an Info.plist beside the link instead.
    private static var appBundle: Bundle {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) ?? .main : .main
    }

    /// True when `candidate` is a later version than `current`. Either may start with "v".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// The newest release's tag, such as "v0.2.0", from the GitHub API at `api`.
    static func latestTag(session: URLSession = .shared, api: URL = githubAPI) async throws -> String {
        let json: [String: Any]
        do {
            json = try await HTTP.json(request("releases/latest", api: api), session: session)
        } catch let error as LogosError where error.message.hasPrefix("HTTP 404") {
            throw LogosError("\(repo) has no release yet, or you can't read it. A private repository needs `gh auth login` or GH_TOKEN.")
        }
        guard let tag = json["tag_name"] as? String else { throw LogosError("The latest release has no tag") }
        return tag
    }

    /// Downloads install.sh as of `tag` to a temporary file.
    static func installer(tag: String) async throws -> URL {
        var request = request("contents/install.sh?ref=\(tag)")
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LogosError("Couldn't download install.sh for \(tag): HTTP \(status)") }
        let url = FileManager.default.temporaryDirectory.appending(path: "logos-install-\(UUID().uuidString).sh")
        try data.write(to: url)
        return url
    }

    /// A process that runs `installer` to build and install `tag`.
    static func installProcess(installer: URL, tag: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer.path]
        var environment = ProcessInfo.processInfo.environment
        environment["LOGOS_REF"] = tag
        environment["LOGOS_REPO"] = repo
        environment["PATH"] = searchPath
        if let token { environment["GH_TOKEN"] = token }
        process.environment = environment
        return process
    }

    // MARK: Checks

    /// What a check that you ask for found: a newer release to offer, the
    /// newest release when it's no newer than this copy, or why it failed.
    enum CheckResult: Equatable {
        case newer(String)
        case upToDate(latest: String)
        case failed(String)
    }

    /// Asks GitHub for the newest release now, whatever the cache holds, for
    /// Check for Updates… in the menu. Saves the answer to the cache, so the
    /// automatic check starts from it. Runs even when LOGOS_OFFLINE is set,
    /// because you asked for it.
    static func check(installed: String = installedVersion, cache: URL = cacheFile,
                      fetch: () async throws -> String = { try await latestTag() }) async -> CheckResult {
        do {
            let tag = try await fetch()
            save(Check(tag: tag, checked: Date()), to: cache)
            return isNewer(tag, than: installed) ? .newer(tag) : .upToDate(latest: tag)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The tag of a release newer than `installed`, found the way Logos looks on
    /// its own: through the daily cache, and not at all when `enabled`, the
    /// checkForUpdates setting, is false.
    static func automaticCheck(enabled: Bool, installed: String = installedVersion,
                               latest: () async -> String? = { await latestTagCached() }) async -> String? {
        guard enabled, let tag = await latest(), isNewer(tag, than: installed) else { return nil }
        return tag
    }

    private struct Check: Codable {
        var tag: String
        var checked: Date
    }

    static var cacheFile: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache")
        return base.appending(path: "logos/release.json")
    }

    /// The newest release's tag, asking GitHub at most once a day. Nil when
    /// `offline`, which LOGOS_OFFLINE sets by default, or when GitHub can't be
    /// reached.
    static func latestTagCached(maxAge: TimeInterval = 86_400, cache: URL = cacheFile,
                                offline: Bool = ProcessInfo.processInfo.environment["LOGOS_OFFLINE"] != nil,
                                fetch: () async throws -> String = { try await latestTag() }) async -> String? {
        guard !offline else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: cache),
           let check = try? decoder.decode(Check.self, from: data),
           Date().timeIntervalSince(check.checked) < maxAge {
            return check.tag
        }
        guard let tag = try? await fetch() else { return nil }
        save(Check(tag: tag, checked: Date()), to: cache)
        return tag
    }

    // MARK: Install progress

    /// How far an update has got, from the installer's log so far, such as
    /// "building 59%".
    static func progress(log: String) -> String {
        var stage = "downloading"
        for line in log.split(separator: "\n") {
            if line.hasPrefix("Installed Logos") || line.hasPrefix("Built ") {
                stage = "installing"
            } else if line.hasPrefix("Building") || line.hasPrefix("[Planning") {
                stage = "building"
            } else if line.hasPrefix("["), let slash = line.firstIndex(of: "/"), let close = line.firstIndex(of: "]"),
                      let done = Int(line[line.index(after: line.startIndex)..<slash].trimmingCharacters(in: .whitespaces)),
                      let total = Int(line[line.index(after: slash)..<close].trimmingCharacters(in: .whitespaces)), total > 0 {
                stage = "building \(min(99, done * 100 / total))%"
            }
        }
        return stage
    }

    /// An update that has started, recorded so the version it starts can say
    /// whether it took.
    struct PendingUpdate: Codable, Equatable {
        var from: String
        var to: String
    }

    static var pendingFile: URL { cacheFile.deletingLastPathComponent().appending(path: "update.json") }

    static func recordPending(_ update: PendingUpdate, at file: URL = pendingFile) {
        guard let data = try? JSONEncoder().encode(update) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The pending update, if any, removing its record so it's reported once.
    static func takePending(at file: URL = pendingFile) -> PendingUpdate? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PendingUpdate.self, from: data)
    }

    /// What to tell you when Logos starts after an update, and whether it worked.
    static func launchMessage(after update: PendingUpdate, installed: String = installedVersion) -> (text: String, success: Bool) {
        let target = update.to.hasPrefix("v") ? String(update.to.dropFirst()) : update.to
        if installed == target { return ("Updated to Logos \(installed)", true) }
        return ("The update to Logos \(target) didn't finish, so this is still \(installed). See \(Paths.updateLog.path).", false)
    }

    private static func save(_ check: Check, to cache: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(check) else { return }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
    }

    // MARK: GitHub access

    static let githubAPI = URL(string: "https://api.github.com")!

    private static func request(_ path: String, api: URL = githubAPI) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(api.absoluteString)/repos/\(repo)/\(path)")!)
        // GitHub lets clients keep an answer for 60 seconds, so without this a
        // check just after a release would repeat the stale answer it got before.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("logos-cli", forHTTPHeaderField: "User-Agent")
        // The token is for GitHub alone, never for a server that stands in for it.
        if api == githubAPI, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Apps opened from Finder don't get the shell's PATH, so add where Homebrew puts `gh`.
    private static var searchPath: String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path + ":/opt/homebrew/bin:/usr/local/bin"
    }

    /// GH_TOKEN or GITHUB_TOKEN, or else the token of a logged-in `gh`.
    private static let token: String? = {
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"], !token.isEmpty { return token }
        for dir in searchPath.split(separator: ":") {
            let gh = "\(dir)/gh"
            guard FileManager.default.isExecutableFile(atPath: gh) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
        return nil
    }()
}
