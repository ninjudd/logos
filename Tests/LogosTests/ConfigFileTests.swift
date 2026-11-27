import Foundation
import Testing
@testable import Logos

@Suite struct ConfigFileTests {
    private let url = FileManager.default.temporaryDirectory.appending(path: "logos-config-\(UUID().uuidString).json")

    private func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    // Catches Settings rewriting the whole file from its own model, which would
    // drop hand-written settings such as providers and extraBody.
    @Test func setKeepsEveryOtherKey() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"cleanup": {"model": "a/b", "extraBody": {"temperature": 0}}, "myNote": "keep me"}"#.utf8).write(to: url)
        try ConfigFile.set("anthropic/claude-haiku-5-5", at: ["cleanup", "model"], in: url)

        let root = try json()
        let cleanup = root["cleanup"] as! [String: Any]
        #expect(cleanup["model"] as? String == "anthropic/claude-haiku-5-5")
        #expect((cleanup["extraBody"] as? [String: Any])?["temperature"] as? Int == 0)
        #expect(root["myNote"] as? String == "keep me")
    }

    @Test func setCreatesAMissingFileAndSections() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try ConfigFile.set("sk-test", at: ["keys", "anthropic"], in: url)
        #expect((try json()["keys"] as? [String: Any])?["anthropic"] as? String == "sk-test")
        #expect(try Config.decode(Data(contentsOf: url)).keys["anthropic"] == "sk-test")
    }

    // Catches Settings replacing a file the user is halfway through editing by hand.
    @Test func invalidJSONIsLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let broken = #"{"cleanup": {"model": "a/b",}"#
        try Data(broken.utf8).write(to: url)
        #expect(throws: (any Error).self) { try ConfigFile.set(true, at: ["saveHistory"], in: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)
    }

    // Catches the API keys file becoming readable by other users.
    @Test func fileIsReadableOnlyByYou() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try ConfigFile.set("sk-test", at: ["keys", "anthropic"], in: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
