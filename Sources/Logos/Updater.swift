import Foundation

/// Finds the newest Logos release on GitHub and installs it by running that
/// release's own install.sh, which builds it from source on this Mac.
enum Updater {
    static var repo: String { ProcessInfo.processInfo.environment["LOGOS_REPO"] ?? "ninjudd/logos" }

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
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

    /// The newest release's tag, such as "v0.2.0".
    static func latestTag() async throws -> String {
        let json: [String: Any]
        do {
            json = try await HTTP.json(request("releases/latest"))
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

    // MARK: Daily check

    private struct Check: Codable {
        var tag: String
        var checked: Date
    }

    private static var cacheFile: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache")
        return base.appending(path: "logos/release.json")
    }

    /// The newest release's tag, asking GitHub at most once a day. Nil when
    /// offline, when LOGOS_OFFLINE is set, or when GitHub can't be reached.
    static func latestTagCached(maxAge: TimeInterval = 86_400) async -> String? {
        guard ProcessInfo.processInfo.environment["LOGOS_OFFLINE"] == nil else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: cacheFile),
           let check = try? decoder.decode(Check.self, from: data),
           Date().timeIntervalSince(check.checked) < maxAge {
            return check.tag
        }
        guard let tag = try? await latestTag() else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Check(tag: tag, checked: Date())) {
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return tag
    }

    // MARK: GitHub access

    private static func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("logos-cli", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
