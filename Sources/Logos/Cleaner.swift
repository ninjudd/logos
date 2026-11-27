import Foundation

/// Sends the raw transcript and your prompt to the configured model and returns its reply.
enum Cleaner {
    /// Models that accept the server-side refusal fallback (`fallbacks: "default"`).
    private static let fallbackModels: Set<String> = [
        "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
    ]

    static func clean(_ transcript: String, prompt: String, app: String, vocabulary: [Vocabulary.Entry],
                      context: AppContext, config: Config) async throws -> String {
        let (system, user) = messages(prompt: prompt, transcript: transcript, app: app, vocabulary: vocabulary,
                                      context: context)
        let model = try config.resolve(config.cleanup.model)
        switch model.api {
        case "anthropic": return try await anthropic(system: system, user: user, model: model, settings: config.cleanup)
        case "openai": return try await openAI(system: system, user: user, model: model, settings: config.cleanup)
        default: throw LogosError("Provider \"\(model.provider)\" has unknown api \"\(model.api)\" (use \"anthropic\" or \"openai\")")
        }
    }

    /// A prompt with {{transcript}} is sent whole as the user message, with no
    /// system prompt. Otherwise the prompt is the system prompt and the
    /// transcript is the user message. Placeholders are filled in one pass, so
    /// text that came from you, a field, or an app is never substituted again.
    static func messages(prompt: String, transcript: String, app: String,
                         vocabulary: [Vocabulary.Entry] = [],
                         context: AppContext = AppContext()) -> (system: String?, user: String) {
        var values = ["app": app, "dictionary": Vocabulary.promptList(vocabulary), "context": context.render()]
        let inline = prompt.contains("{{transcript}}")
        if inline { values["transcript"] = transcript }
        let rendered = fill(prompt, values)
        return inline ? (nil, rendered) : (rendered, "<transcript>\n\(transcript)\n</transcript>")
    }

    /// Replaces each {{name}} that has a value, leaving unknown ones as they are.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var output = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "}}"), let value = values[String(after[..<close.lowerBound])] {
                output += value
                rest = after[close.upperBound...]
            } else {
                output += "{{"
                rest = after
            }
        }
        return output + rest
    }

    private static func anthropic(system: String?, user: String, model: ResolvedModel, settings: Config.Cleanup) async throws -> String {
        guard !model.apiKey.isEmpty else { throw LogosError("No \(model.provider) key under \"keys\" in config.json") }

        var body: [String: Any] = [
            "model": model.model,
            "max_tokens": settings.maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if let system { body["system"] = system }
        if !settings.effort.isEmpty { body["output_config"] = ["effort": settings.effort] }

        var request = URLRequest(url: model.baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(model.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if fallbackModels.contains(model.model) {
            // If the model declines, the API reruns the request on a fallback model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        for (k, v) in settings.extraBody { body[k] = v.foundation }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await HTTP.json(request)
        if json["stop_reason"] as? String == "refusal" {
            throw LogosError("The model declined to clean up this transcript")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openAI(system: String?, user: String, model: ResolvedModel, settings: Config.Cleanup) async throws -> String {
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        var body: [String: Any] = ["model": model.model, "messages": messages]
        for (k, v) in settings.extraBody { body[k] = v.foundation }

        var request = URLRequest(url: model.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local servers such as Ollama need no key.
        if !model.apiKey.isEmpty { request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await HTTP.json(request)
        let choices = json["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any], let text = message["content"] as? String else {
            throw LogosError("Cleanup response had no message content")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
