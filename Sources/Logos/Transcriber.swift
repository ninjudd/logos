import AVFoundation
import Foundation
import Speech

enum Transcriber {
    static func transcribe(_ audio: URL, config: Config) async throws -> String {
        let settings = config.transcription
        if settings.model == "apple" { return try await apple(audio, localeID: settings.locale) }
        let resolved = try config.resolve(settings.model)
        guard resolved.api == "openai" else {
            throw LogosError("Provider \"\(resolved.provider)\" has no transcription API. Use \"apple\" or an OpenAI-compatible provider.")
        }
        return try await openAI(audio, model: resolved, settings: settings)
    }

    /// Downloads the on-device speech model ahead of the first dictation.
    static func prepare(_ config: Config.Transcription) async {
        guard config.model == "apple" else { return }
        _ = try? await appleTranscriber(localeID: config.locale)
    }

    // MARK: Apple on-device

    private static func appleTranscriber(localeID: String) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw LogosError("On-device transcription doesn't support locale \(localeID)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    private static func apple(_ audio: URL, localeID: String) async throws -> String {
        let transcriber = try await appleTranscriber(localeID: localeID)
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: OpenAI-compatible

    private static func openAI(_ audio: URL, model: ResolvedModel, settings: Config.Transcription) async throws -> String {
        var form = MultipartForm()
        form.add("model", model.model)
        form.add("response_format", "json")
        if !settings.prompt.isEmpty { form.add("prompt", settings.prompt) }
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
    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
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
