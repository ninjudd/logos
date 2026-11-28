import Foundation

/// Audio file in, text to paste out: transcribe, then clean up.
enum Pipeline {
    struct Outcome {
        var raw: String
        var text: String
        /// Set when cleanup was skipped or failed and the raw transcript is used instead.
        var warning: String?
        /// What the speech model returned that NoSpeech kept out of `raw`.
        var dropped: NoSpeech.Dropped?
    }

    static func run(audio: URL, config: Config, prompt: String, vocabulary: [Vocabulary.Entry], app: String,
                    context: AppContext = AppContext(),
                    stage: @escaping (String) -> Void = { _ in }) async throws -> Outcome {
        let started = Date()
        // A file Logos can't measure goes to the speech model, which may read it.
        let level = try? Loudness.peakDB(of: audio)
        let silent = level.map { Loudness.isSilent($0, threshold: config.silenceThresholdDB) } ?? false
        var transcript = NoSpeech.Transcript(text: "")
        if !silent {
            stage("Transcribing…")
            transcript = try await Transcriber.transcribe(audio, config: config, vocabulary: vocabulary, peakDB: level)
        }
        let raw = transcript.text
        let transcribed = Date()
        var context = context
        context.hints += People.hints(for: raw, config: config, people: ContactsIndex.shared.people,
                                      cardEmails: ContactsIndex.shared.ownEmails)

        var outcome = Outcome(raw: raw, text: raw, dropped: transcript.dropped)
        if raw.isEmpty {
            outcome.warning = "No speech detected"
        } else if config.cleanup.enabled {
            stage("Cleaning up…")
            do {
                outcome.text = try await Cleaner.clean(raw, prompt: prompt, app: app, vocabulary: vocabulary,
                                                       context: context, config: config)
            } catch {
                outcome.warning = "Cleanup failed, pasted raw text: \(error.localizedDescription)"
            }
        }

        if config.saveHistory {
            var entry: [String: Any] = [
                "time": ISO8601DateFormatter().string(from: started),
                "app": app,
                "raw": raw,
                "text": outcome.text,
                "transcriptionModel": config.transcription.model,
                "cleanupModel": config.cleanup.enabled ? config.cleanup.model : "",
                "transcribeSeconds": (transcribed.timeIntervalSince(started) * 100).rounded() / 100,
                "cleanupSeconds": (Date().timeIntervalSince(transcribed) * 100).rounded() / 100,
                "warning": outcome.warning ?? "",
                "peakDB": level.map { ($0 * 10).rounded() / 10 as Any } ?? NSNull(),
            ]
            if let dropped = outcome.dropped {
                entry["dropped"] = dropped.text
                entry["droppedReason"] = dropped.reason.rawValue
            }
            History.append(entry)
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
