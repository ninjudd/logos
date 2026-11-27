import Foundation

/// Audio file in, text to paste out: transcribe, then clean up.
enum Pipeline {
    struct Outcome {
        var raw: String
        var text: String
        /// Set when cleanup was skipped or failed and the raw transcript is used instead.
        var warning: String?
    }

    static func run(audio: URL, config: Config, prompt: String, app: String,
                    stage: @escaping (String) -> Void = { _ in }) async throws -> Outcome {
        let started = Date()
        stage("Transcribing…")
        let raw = try await Transcriber.transcribe(audio, config: config)
        let transcribed = Date()

        var outcome = Outcome(raw: raw, text: raw)
        if raw.isEmpty {
            outcome.warning = "No speech detected"
        } else if config.cleanup.enabled {
            stage("Cleaning up…")
            do {
                outcome.text = try await Cleaner.clean(raw, prompt: prompt, app: app, config: config)
            } catch {
                outcome.warning = "Cleanup failed, pasted raw text: \(error.localizedDescription)"
            }
        }

        if config.saveHistory {
            History.append([
                "time": ISO8601DateFormatter().string(from: started),
                "app": app,
                "raw": raw,
                "text": outcome.text,
                "transcriptionModel": config.transcription.model,
                "cleanupModel": config.cleanup.enabled ? config.cleanup.model : "",
                "transcribeSeconds": (transcribed.timeIntervalSince(started) * 100).rounded() / 100,
                "cleanupSeconds": (Date().timeIntervalSince(transcribed) * 100).rounded() / 100,
                "warning": outcome.warning ?? "",
            ])
        }
        return outcome
    }
}

enum History {
    static func append(_ entry: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: Paths.history) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: Paths.history)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.history.path)
        }
    }
}
