import AVFoundation
import Foundation
import Speech

enum Transcriber {
    /// Transcribes `audio`, listening especially for the words in `vocabulary`.
    /// Transcription models get only the words; their notes are for cleanup.
    static func transcribe(_ audio: URL, config: Config, vocabulary entries: [Vocabulary.Entry]) async throws -> String {
        let vocabulary = entries.map(\.term)
        let settings = config.transcription
        if let apple = AppleModel(settings.model) {
            return try await apple.transcribe(audio, localeID: settings.locale, vocabulary: vocabulary)
        }
        let resolved = try config.resolve(settings.model)
        guard resolved.api == "openai" else {
            throw LogosError("Provider \"\(resolved.provider)\" has no transcription API. Use \"apple\" or an OpenAI-compatible provider.")
        }
        return try await openAI(audio, model: resolved, settings: settings, vocabulary: vocabulary)
    }

    /// Downloads the on-device speech model ahead of the first dictation.
    static func prepare(_ config: Config.Transcription) async {
        _ = try? await AppleModel(config.model)?.installAssets(localeID: config.locale)
    }

    // MARK: Apple on-device

    /// Apple's two on-device models. "apple" is SpeechTranscriber, the newer
    /// general model. "apple/dictation" is DictationTranscriber, the model behind
    /// macOS keyboard dictation. Only DictationTranscriber listens for the words
    /// in dictionary.txt; SpeechTranscriber ignores them.
    enum AppleModel: Equatable {
        case speech, dictation

        init?(_ name: String) {
            switch name {
            case "apple", "apple/speech": self = .speech
            case "apple/dictation": self = .dictation
            default: return nil
            }
        }

        func transcribe(_ audio: URL, localeID: String, vocabulary: [String]) async throws -> String {
            let locale = try await supportedLocale(localeID)
            switch self {
            case .speech:
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                return try await analyze(audio, module: module, vocabulary: vocabulary) {
                    var text = ""
                    for try await result in module.results where result.isFinal { text += String(result.text.characters) }
                    return text
                }
            case .dictation:
                let module = DictationTranscriber(locale: locale, preset: .longDictation)
                return try await analyze(audio, module: module, vocabulary: vocabulary) {
                    var text = ""
                    for try await result in module.results where result.isFinal { text += String(result.text.characters) }
                    return text
                }
            }
        }

        /// Downloads the model for `localeID`, ahead of the first dictation.
        func installAssets(localeID: String) async throws {
            let locale = try await supportedLocale(localeID)
            let module: any SpeechModule = self == .speech
                ? SpeechTranscriber(locale: locale, preset: .transcription)
                : DictationTranscriber(locale: locale, preset: .longDictation)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }

        private func supportedLocale(_ id: String) async throws -> Locale {
            let wanted = Locale(identifier: id)
            let locale = self == .speech
                ? await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
                : await DictationTranscriber.supportedLocale(equivalentTo: wanted)
            guard let locale else { throw LogosError("On-device transcription doesn't support locale \(id)") }
            return locale
        }

        private func analyze(_ audio: URL, module: any SpeechModule, vocabulary: [String],
                             results: @escaping () async throws -> String) async throws -> String {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let context = AnalysisContext()
            if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }
            let collector = Task { try await results() }
            do {
                // The context goes in when the analyzer is created; setting it
                // afterwards had no effect in testing.
                _ = try await SpeechAnalyzer(inputAudioFile: AVAudioFile(forReading: audio), modules: [module],
                                             analysisContext: context, finishAfterFile: true)
            } catch {
                collector.cancel()
                throw error
            }
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: OpenAI-compatible

    private static func openAI(_ audio: URL, model: ResolvedModel, settings: Config.Transcription,
                               vocabulary: [String]) async throws -> String {
        var form = MultipartForm()
        form.add("model", model.model)
        form.add("response_format", "json")
        let hint = Vocabulary.transcriptionHint(settings.prompt, words: vocabulary)
        if !hint.isEmpty { form.add("prompt", hint) }
        if let language = Locale(identifier: settings.locale).language.languageCode?.identifier {
            form.add("language", language)
        }
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: try Data(contentsOf: audio))

        var request = URLRequest(url: model.baseURL.appending(path: "audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        if !model.apiKey.isEmpty { request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finish()

        let json = try await HTTP.json(request)
        guard let text = json["text"] as? String else { throw LogosError("Transcription response had no text") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MultipartForm {
    private let boundary = "logos-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    mutating func finish() -> Data {
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

enum HTTP {
    /// Sends the request and returns the JSON object body, throwing the API's own
    /// error message on a non-2xx status.
    static func json(_ request: URLRequest, session: URLSession = .shared) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"]
            let message = (error as? [String: Any])?["message"] as? String
                ?? error as? String
                ?? String(data: data.prefix(300), encoding: .utf8)
                ?? ""
            throw LogosError("HTTP \(status): \(message)")
        }
        guard let json else { throw LogosError("Response wasn't a JSON object") }
        return json
    }
}
