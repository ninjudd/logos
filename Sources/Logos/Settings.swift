import AppKit
import SwiftUI

/// Writes single settings into config.json. Every other key stays as it is,
/// including ones Logos doesn't know, so hand-written settings survive.
enum ConfigFile {
    static func set(_ value: Any, at path: [String], in url: URL = Paths.config) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LogosError("config.json isn't valid JSON, so Settings won't overwrite it. Fix it in a text editor first.")
            }
            root = object
        }
        root = setting(value, at: path[...], in: root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        // The file holds API keys.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func setting(_ value: Any, at path: ArraySlice<String>, in dict: [String: Any]) -> [String: Any] {
        guard let key = path.first else { return dict }
        var dict = dict
        dict[key] = path.count == 1 ? value : setting(value, at: path.dropFirst(), in: dict[key] as? [String: Any] ?? [:])
        return dict
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config = Config()
    @Published var prompt = ""
    @Published var dictionary = ""
    @Published var error: String?
    private var pendingSaves: [String: Task<Void, Never>] = [:]

    /// Reads all three files again, so edits made elsewhere show up.
    func reload() {
        config = ConfigStore.shared.current
        error = ConfigStore.shared.lastError
        prompt = (try? String(contentsOf: Paths.prompt, encoding: .utf8)) ?? DefaultPrompt.text
        dictionary = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? Vocabulary.defaultText
    }

    /// A binding to one setting that saves it to config.json shortly after it changes.
    func binding<T>(_ keyPath: WritableKeyPath<Config, T>, _ path: [String],
                    json: @escaping (T) -> Any = { $0 }) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in
                self.config[keyPath: keyPath] = value
                self.save(path.joined(separator: ".")) { try ConfigFile.set(json(value), at: path) }
            })
    }

    func key(_ provider: String) -> Binding<String> {
        Binding(
            get: { self.config.keys[provider] ?? "" },
            set: { value in
                self.config.keys[provider] = value
                self.save("keys.\(provider)") { try ConfigFile.set(value, at: ["keys", provider]) }
            })
    }

    var promptText: Binding<String> {
        Binding(get: { self.prompt }, set: { text in
            self.prompt = text
            self.save("prompt") { try text.write(to: Paths.prompt, atomically: true, encoding: .utf8) }
        })
    }

    var dictionaryText: Binding<String> {
        Binding(get: { self.dictionary }, set: { text in
            self.dictionary = text
            self.save("dictionary") { try text.write(to: Paths.dictionary, atomically: true, encoding: .utf8) }
        })
    }

    /// Saves after typing pauses, so a burst of keystrokes writes the file once.
    private func save(_ id: String, _ write: @escaping () throws -> Void) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try write()
                self.error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            ConfigTab(model: model).tabItem { Label("Config", systemImage: "gearshape") }
            TextFileTab(
                text: model.promptText,
                help: "The cleanup prompt. {{app}} becomes the app you're dictating into, and {{dictionary}} the words in your dictionary. With {{transcript}}, the whole prompt is sent as one message with the transcript in that spot.",
                file: Paths.prompt,
                status: nil
            ).tabItem { Label("Prompt", systemImage: "text.bubble") }
            TextFileTab(
                text: model.dictionaryText,
                help: "Words and names to transcribe and spell exactly, one per line. Context chooses their letter case; to say how, add a note after \": \", such as  logos: \"Logos\" for the app, \"logos\" for the command. Lines starting with # are ignored.",
                file: Paths.dictionary,
                status: "\(Vocabulary.parse(model.dictionary).count) words"
            ).tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 520)
    }
}

private struct ConfigTab: View {
    @ObservedObject var model: SettingsModel

    private static let transcriptionModels = [
        "apple", "apple/dictation", "openai/gpt-4o-transcribe", "openai/gpt-4o-mini-transcribe",
        "groq/whisper-large-v3-turbo",
    ]
    private static let cleanupModels = [
        "anthropic/claude-opus-5-5", "anthropic/claude-sonnet-5-5", "anthropic/claude-haiku-5-5",
    ]
    private static let efforts = ["", "low", "medium", "high", "xhigh", "max"]

    var body: some View {
        Form {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section("Dictation") {
                Picker("Hold to dictate", selection: model.binding(\.hotkey, ["hotkey"]) { $0.rawValue }) {
                    Text("Either Option key").tag(Config.Hotkey.option)
                    Text("Left Option").tag(Config.Hotkey.leftOption)
                    Text("Right Option").tag(Config.Hotkey.rightOption)
                }
                TextField("Shortest hold, in seconds", value: model.binding(\.minHoldSeconds, ["minHoldSeconds"]),
                          format: .number)
                Toggle("Add a space after each paste", isOn: model.binding(\.trailingSpace, ["trailingSpace"]))
                Toggle("Put the clipboard back after pasting", isOn: model.binding(\.restoreClipboard, ["restoreClipboard"]))
                Toggle("Show a card when there's no text field", isOn: model.binding(\.showWhenNoTextField, ["showWhenNoTextField"]))
                Toggle("Keep a history of dictations", isOn: model.binding(\.saveHistory, ["saveHistory"]))
            }
            Section("Transcription") {
                ModelField(title: "Model", value: model.binding(\.transcription.model, ["transcription", "model"]),
                           suggestions: Self.transcriptionModels)
                TextField("Language", text: model.binding(\.transcription.locale, ["transcription", "locale"]))
                TextField("Hint for API models", text: model.binding(\.transcription.prompt, ["transcription", "prompt"]))
            }
            Section("Cleanup") {
                Toggle("Clean up transcripts", isOn: model.binding(\.cleanup.enabled, ["cleanup", "enabled"]))
                ModelField(title: "Model", value: model.binding(\.cleanup.model, ["cleanup", "model"]),
                           suggestions: Self.cleanupModels)
                Picker("Effort (Anthropic)", selection: model.binding(\.cleanup.effort, ["cleanup", "effort"])) {
                    ForEach(Self.efforts, id: \.self) { Text($0.isEmpty ? "Model default" : $0).tag($0) }
                }
                TextField("Most tokens in a reply", value: model.binding(\.cleanup.maxTokens, ["cleanup", "maxTokens"]),
                          format: .number)
            }
            Section("API keys") {
                ForEach(providers, id: \.self) { provider in
                    SecureField(provider, text: model.key(provider))
                }
            }
            Section {
                HStack {
                    Text("Providers, extra request settings, and apps that always paste live in config.json.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open config.json") { NSWorkspace.shared.open(Paths.config) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The common providers, plus any others the config has a key for.
    private var providers: [String] {
        let common = ["anthropic", "openai", "groq", "openrouter"]
        return common + model.config.keys.keys.filter { !common.contains($0) }.sorted()
    }
}

/// A text field for a "provider/model" string, with a menu of common choices.
private struct ModelField: View {
    let title: String
    @Binding var value: String
    let suggestions: [String]

    var body: some View {
        HStack {
            TextField(title, text: $value)
            Menu {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { value = suggestion }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// An editor for a whole text file, saved as you type.
private struct TextFileTab: View {
    @Binding var text: String
    let help: String
    let file: URL
    let status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(help).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Text(["Saved automatically", status].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            .font(.callout)
        }
        .padding(4)
    }
}

/// The Settings window, created the first time it's opened.
@MainActor
final class SettingsWindowController {
    private let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Logos Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
