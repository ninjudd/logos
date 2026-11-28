import Foundation

/// Spots a transcript of a recording that holds no words, such as a breath, a
/// click, or a keypress. Whisper models given such a recording tend to answer
/// by continuing their `prompt`, which lists the dictionary and ends with "…":
/// with the "…", with words from the list, or with a stock phrase such as
/// "Thank you." These checks run on the transcripts of
/// OpenAI-compatible APIs. Apple's on-device models take the dictionary as a
/// list of words, not as a `prompt`, so the checks leave them alone.
enum NoSpeech {
    /// A transcript, and the text Logos dropped from it as no speech.
    struct Transcript: Equatable {
        var text: String
        var dropped: Dropped?
    }

    /// Text the model returned that Logos didn't paste, and the check that dropped it.
    struct Dropped: Equatable {
        var text: String
        var reason: Reason
    }

    enum Reason: String {
        /// Whisper marked the text's segments as having no speech.
        case noSpeech
        /// The text repeats the `prompt` or a stock phrase, from a quiet recording.
        case echo
    }

    /// A stretch of a Whisper transcript, as a `verbose_json` response gives it.
    struct Segment: Equatable {
        var text: String
        /// Whisper's probability that the stretch holds no speech.
        var noSpeechProb: Double?
        /// The mean log probability of the stretch's tokens. Near 0 is confident.
        var avgLogprob: Double?

        /// Whether Whisper's reference decoder would skip this stretch as silence.
        /// It skips a stretch whose `no_speech_prob` is above `no_speech_threshold`
        /// (0.6), unless its `avg_logprob` is above `logprob_threshold` (-1.0). See
        /// `transcribe()` in whisper/transcribe.py in github.com/openai/whisper.
        /// A segment without both values is kept.
        var isSilent: Bool {
            guard let noSpeechProb, let avgLogprob else { return false }
            return noSpeechProb > 0.6 && !(avgLogprob > -1.0)
        }
    }

    /// A transcription API's response: its whole text, and its segments when the
    /// response has them. A `json` response has none, and `verbose_json` has them.
    struct Response: Equatable {
        var text: String
        var segments: [Segment]?

        /// Nil when the response has no `text`.
        init?(json: [String: Any]) {
            guard let text = json["text"] as? String else { return nil }
            self.text = text
            segments = (json["segments"] as? [[String: Any]])?.map { segment in
                Segment(text: segment["text"] as? String ?? "",
                        noSpeechProb: (segment["no_speech_prob"] as? NSNumber)?.doubleValue,
                        avgLogprob: (segment["avg_logprob"] as? NSNumber)?.doubleValue)
            }
        }

        init(text: String, segments: [Segment]? = nil) {
            self.text = text
            self.segments = segments
        }

        /// The text, less the segments that Whisper marks as silent. When no
        /// segment is silent, the whole `text`.
        var speech: String {
            guard let segments, segments.contains(where: \.isSilent) else { return text.trimmed }
            return segments.filter { !$0.isSilent }.map(\.text).joined().trimmed
        }

        /// The highest no-speech probability of any segment, or nil without one.
        var noSpeechProb: Double? {
            segments?.compactMap(\.noSpeechProb).max()
        }
    }

    /// How far above `silenceThresholdDB` a recording's loudest 50 ms can reach,
    /// in decibels, and still have an echo dropped. With the default threshold of
    /// -45, the ceiling is -30 dBFS. Echoes of the prompt from a breath or a
    /// click measured -39 to -33 dBFS, and full sentences of soft speech measured
    /// -33 dBFS and up. A deliberate one-word dictation quieter than the ceiling,
    /// of a word in the prompt, is dropped too, and history.jsonl shows it. Tying
    /// the ceiling to the threshold lowers it for someone who lowers the threshold
    /// for soft speech, and a threshold of -100 turns this check off too.
    static let echoMarginDB = 15.0

    /// A no-speech probability at or above this is borderline: half of Whisper's
    /// own 0.6. A breath that a Whisper model answered with "Thank you." scored
    /// 0.43, and speech scored 0.01 or less. Some models, such as Groq's
    /// whisper-large-v3-turbo, always report 0, so the level check carries them.
    static let borderlineNoSpeechProb = 0.3

    /// Phrases Whisper models are known to produce from silence or noise, taken
    /// from the captions of videos they were trained on, and filler words.
    static let stockPhrases: Set<String> = [
        "you", "bye", "thanks", "thank you", "thank you very much",
        "thanks for watching", "thank you for watching", "thanks for listening",
        "thank you for listening", "please subscribe",
        "uh", "um", "hmm", "mm", "ah",
    ]

    /// What Logos pastes from `response`: the text without Whisper's silent
    /// segments, or nothing when the whole transcript looks like no speech.
    /// `hint` is the `prompt` the model got. `peakDB` is the recording's loudest
    /// 50 ms, nil when Logos couldn't measure it.
    static func filter(_ response: Response, hint: String, peakDB: Double?,
                       silenceThresholdDB: Double) -> Transcript {
        let original = response.text.trimmed
        let speech = response.speech
        if speech.isEmpty {
            return Transcript(text: "", dropped: original.isEmpty ? nil : Dropped(text: original, reason: .noSpeech))
        }
        // Punctuation alone, such as the "…" that ends the hint, holds nothing
        // you said at any level, so it needs no level check.
        if words(speech).isEmpty
            || isEcho(speech, hint: hint)
            && (isQuiet(peakDB, silenceThresholdDB: silenceThresholdDB) || isBorderline(response.noSpeechProb)) {
            return Transcript(text: "", dropped: Dropped(text: original, reason: .echo))
        }
        return Transcript(text: speech, dropped: speech == original ? nil : Dropped(text: original, reason: .noSpeech))
    }

    /// Whether `transcript`, ignoring case, punctuation, and spacing, is what a
    /// model says to no words: nothing but punctuation, a stock phrase, or a
    /// run of consecutive words from `hint`. A model was seen echoing the hint's
    /// last word, its last two, and "Vocabulary", the word that starts its list.
    static func isEcho(_ transcript: String, hint: String) -> Bool {
        let said = words(transcript)
        if said.isEmpty || stockPhrases.contains(said.joined(separator: " ")) { return true }
        let hinted = words(hint)
        guard said.count <= hinted.count else { return false }
        return (0...(hinted.count - said.count)).contains { start in
            hinted[start..<start + said.count].elementsEqual(said)
        }
    }

    /// The letters and digits of `text`, as lowercase words without accents.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func isQuiet(_ peakDB: Double?, silenceThresholdDB: Double) -> Bool {
        guard let peakDB else { return false }
        return peakDB < silenceThresholdDB + echoMarginDB
    }

    private static func isBorderline(_ noSpeechProb: Double?) -> Bool {
        guard let noSpeechProb else { return false }
        return noSpeechProb >= borderlineNoSpeechProb
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
