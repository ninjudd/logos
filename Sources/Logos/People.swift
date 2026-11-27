import Contacts
import Foundation

/// Your contacts, matched against each transcript on your Mac. Only the names of
/// the few people a dictation seems to mention reach the cleanup model, so it
/// can spell them. Their email addresses are never read, so they can't be sent.
enum People {
    struct Person: Equatable {
        let given: String
        let family: String
        let nickname: String
        /// The name parts long enough to match, worked out once when the
        /// contact loads rather than at every dictation.
        let parts: [Part]

        struct Part: Equatable {
            var spelling: Spelling
            /// A first name or nickname, which has short forms such as "Jon"
            /// for "Jonathan". Surnames don't.
            var isFirstName: Bool
        }

        init(given: String, family: String, nickname: String) {
            self.given = given
            self.family = family
            self.nickname = nickname
            parts = [(given, true), (nickname, true), (family, false)]
                .filter { $0.0.count >= 3 }
                .map { Part(spelling: Spelling($0.0), isFirstName: $0.1) }
        }

        var name: String { [given, family].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// A name or a word, lowercased, with its sound key, so that matching
    /// compares stored values.
    struct Spelling: Equatable {
        let text: String
        let letters: [Character]
        let key: String

        init(_ text: String) {
            self.text = text.lowercased()
            letters = Array(self.text)
            key = People.metaphone(text)
        }
    }

    /// The most people one dictation sends to the cleanup model.
    static let limit = 5
    /// The most of those that may rest on a single name, such as "Jon" alone.
    static let singleNameLimit = 2

    /// A word of a transcript, with what its position says about it.
    struct Word: Equatable {
        let text: String
        let capitalized: Bool
        /// The first word of the transcript or of a sentence, which is capitalized
        /// whether or not it's a name.
        let sentenceStart: Bool
        let spelling: Spelling

        init(text: String, capitalized: Bool, sentenceStart: Bool) {
            self.text = text
            self.capitalized = capitalized
            self.sentenceStart = sentenceStart
            spelling = Spelling(text)
        }

        /// Capitalized where an ordinary word wouldn't be, so likely a name.
        var looksLikeAName: Bool { capitalized && !sentenceStart }
    }

    static func words(_ transcript: String) -> [Word] {
        var words: [Word] = []
        var current = ""
        var atStart = true
        for character in transcript + " " {
            if character.isLetter || character.isNumber {
                current.append(character)
                continue
            }
            if !current.isEmpty {
                words.append(Word(text: current, capitalized: current.first!.isUppercase, sentenceStart: atStart))
                current = ""
                atStart = false
            }
            if ".!?\n".contains(character) { atStart = true }
        }
        return words
    }

    /// How a transcript word matches a name part, strongest first.
    enum Match: Int, Comparable {
        case shortForm = 1, similar, soundsAlike, exact
        static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    /// How `word` matches the name part `part`, if at all. `isFirstName` allows
    /// short forms such as "Jon" for "Jonathan", which surnames don't have.
    static func match(_ word: Spelling, _ part: Spelling, isFirstName: Bool) -> Match? {
        let wordCount = word.letters.count, partCount = part.letters.count
        guard wordCount >= 3, partCount >= 3 else { return nil }
        if word.text == part.text { return .exact }
        if word.key.count >= 2, word.key == part.key { return .soundsAlike }
        // Jaro-Winkler rewards a shared start, so it would also rate truncations
        // like "Park" for "Parker" as similar. Keep it to typos of about the same
        // length; first names' short forms are handled below.
        if min(wordCount, partCount) >= 4, abs(wordCount - partCount) <= 1,
           jaroWinkler(word.letters, part.letters) >= 0.9 {
            return .similar
        }
        if isFirstName, part.text.hasPrefix(word.text), partCount - wordCount <= 5 { return .shortForm }
        return nil
    }

    /// The people `transcript` seems to mention, best match first.
    ///
    /// A person counts when one of their names matches a capitalized word,
    /// since speech models capitalize names. A capitalized word that starts a
    /// sentence may be an ordinary word, such as "Will" in "Will you…", so on
    /// its own it counts only as an exact name of five letters or more.
    ///
    /// A first name or nickname directly followed by the last name, in the
    /// same sentence, counts as a full name, such as "Jon Grub", and ranks
    /// above a single name. The pair needs one of those capitals too, or both
    /// words spelled as the contact's are, because ordinary words in a row can
    /// sound like a name: "will write" sounds like William Wright.
    static func mentioned(in transcript: String, among people: [Person], limit: Int = People.limit) -> [Person] {
        let words = words(transcript)
        guard !words.isEmpty else { return [] }
        var scored: [(person: Person, fullName: Bool, score: Int)] = []
        for person in people {
            // The strongest match each word makes with a first name or
            // nickname, which are the same name, and with the last name.
            var first = [Match?](repeating: nil, count: words.count)
            var last = first
            // The strongest match among the words that name the person, so a
            // stray ordinary word can't raise their rank.
            var best: Match?
            for part in person.parts {
                for (i, word) in words.enumerated() {
                    guard let kind = match(word.spelling, part.spelling, isFirstName: part.isFirstName) else { continue }
                    if part.isFirstName { first[i] = max(first[i] ?? kind, kind) } else { last[i] = kind }
                    if word.looksLikeAName || (word.capitalized && kind == .exact && word.text.count >= 5) {
                        best = max(best ?? kind, kind)
                    }
                }
            }
            var fullName: Match?
            for i in words.indices.dropLast() {
                guard let given = first[i], let family = last[i + 1], !words[i + 1].sentenceStart,
                      words[i].looksLikeAName || words[i + 1].looksLikeAName || (given == .exact && family == .exact)
                else { continue }
                fullName = max(fullName ?? given, given, family)
            }
            if let fullName {
                scored.append((person, true, 20 + fullName.rawValue))
            } else if let best {
                scored.append((person, false, 10 + best.rawValue))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.person.name < $1.person.name }
        var chosen: [Person] = [], singles = 0
        for entry in scored where chosen.count < limit {
            if !entry.fullName {
                guard singles < singleNameLimit else { continue }
                singles += 1
            }
            chosen.append(entry.person)
        }
        return chosen
    }

    /// Whether the speaker mentions mail or an address, so their own addresses are
    /// worth sending. "mail" covers "email", "e-mail", and "Gmail".
    static func mentionsEmail(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        return ["mail", "address", "@"].contains { text.contains($0) }
    }

    /// The {{context}} hints for one transcript: the names of the contacts it
    /// mentions, with useContacts, and your own addresses, with includeMyEmails
    /// when it mentions mail. `cardEmails` are the addresses on your own card,
    /// which Logos reads only with useContacts.
    static func hints(for transcript: String, config: Config, people: [Person], cardEmails: [String]) -> [AppContext.Hint] {
        var hints: [AppContext.Hint] = []
        if config.useContacts, let names = hint(for: mentioned(in: transcript, among: people)) {
            hints.append(names)
        }
        if config.includeMyEmails, mentionsEmail(transcript),
           let emails = emailHint((config.useContacts ? cardEmails : []) + config.myEmails) {
            hints.append(emails)
        }
        return hints
    }

    /// The {{context}} hint naming the people a transcript may mention, or nil for none.
    static func hint(for people: [Person]) -> AppContext.Hint? {
        guard !people.isEmpty else { return nil }
        let list = people.map(\.name).joined(separator: "; ")
        return AppContext.Hint(source: "your contacts",
                               text: "People the transcript may mention. When it refers to one of them, spell the name as listed here: \(list).")
    }

    /// The {{context}} hint giving the speaker's own email addresses, each once
    /// whatever its case, or nil for none.
    static func emailHint(_ addresses: [String]) -> AppContext.Hint? {
        var seen = Set<String>()
        let unique = addresses
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !unique.isEmpty else { return nil }
        return AppContext.Hint(source: "your email addresses",
                               text: "The speaker's own email addresses: \(unique.joined(separator: ", ")).")
    }

    /// Splits addresses typed into one field, separated by commas, semicolons, or spaces.
    static func parseEmails(_ text: String) -> [String] {
        text.split(whereSeparator: { ",; \n\t".contains($0) }).map(String.init)
    }

    // MARK: Similarity

    /// Jaro-Winkler similarity from 0 to 1, which favors strings that start alike.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        jaroWinkler(Array(a), Array(b))
    }

    static func jaroWinkler(_ a: [Character], _ b: [Character]) -> Double {
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty ? 1 : 0 }
        let window = max(0, max(a.count, b.count) / 2 - 1)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in a.indices {
            for j in max(0, i - window)..<min(b.count, i + window + 1) where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true
                bMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0, j = 0
        for i in a.indices where aMatched[i] {
            while !bMatched[j] { j += 1 }
            if a[i] != b[j] { transpositions += 1 }
            j += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2) / m) / 3
        let prefix = zip(a, b).prefix(4).prefix { $0 == $1 }.count
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// A Metaphone sound key: words that sound alike in English share one, such
    /// as "Grub" and "Grubb", or "Kristin" and "Kirsten".
    static func metaphone(_ word: String) -> String {
        var w = Array(word.uppercased().filter { $0.isASCII && $0.isLetter })
        guard !w.isEmpty else { return "" }
        if w.count >= 2, ["AE", "GN", "KN", "PN", "WR"].contains(String(w[0...1])) { w.removeFirst() }
        if w.count >= 2, w[0] == "W", w[1] == "H" { w.remove(at: 1) }
        if w[0] == "X" { w[0] = "S" }

        let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
        func at(_ i: Int) -> Character? { w.indices.contains(i) ? w[i] : nil }
        func isVowel(_ i: Int) -> Bool { at(i).map(vowels.contains) ?? false }
        func frontVowel(_ i: Int) -> Bool { at(i).map { "EIY".contains($0) } ?? false }

        var key = ""
        var i = 0
        while i < w.count {
            let c = w[i]
            if c != "C", i > 0, w[i - 1] == c {
                i += 1
                continue
            }
            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { key.append(c) }
            case "B":
                if !(i == w.count - 1 && at(i - 1) == "M") { key.append("B") }
            case "C":
                if at(i + 1) == "I", at(i + 2) == "A" {
                    key.append("X")
                } else if at(i + 1) == "H" {
                    key.append(at(i - 1) == "S" ? "K" : "X")
                    i += 1
                } else if frontVowel(i + 1) {
                    if at(i - 1) != "S" { key.append("S") }
                } else {
                    key.append("K")
                }
            case "D":
                if at(i + 1) == "G", frontVowel(i + 2) {
                    key.append("J")
                    i += 2
                } else {
                    key.append("T")
                }
            case "G":
                if at(i + 1) == "H" {
                    if isVowel(i + 2) { key.append("K") }
                    i += 1
                } else if at(i + 1) == "N", i + 2 == w.count || (at(i + 2) == "E" && at(i + 3) == "D") {
                    break
                } else if frontVowel(i + 1), at(i - 1) != "G" {
                    key.append("J")
                } else {
                    key.append("K")
                }
            case "H":
                if isVowel(i + 1), !(at(i - 1).map { "CGPST".contains($0) } ?? false) { key.append("H") }
            case "K":
                if at(i - 1) != "C" { key.append("K") }
            case "P":
                if at(i + 1) == "H" {
                    key.append("F")
                    i += 1
                } else {
                    key.append("P")
                }
            case "Q":
                key.append("K")
            case "S":
                if at(i + 1) == "H" {
                    key.append("X")
                    i += 1
                } else if at(i + 1) == "I", at(i + 2) == "O" || at(i + 2) == "A" {
                    key.append("X")
                } else {
                    key.append("S")
                }
            case "T":
                if at(i + 1) == "I", at(i + 2) == "O" || at(i + 2) == "A" {
                    key.append("X")
                } else if at(i + 1) == "H" {
                    key.append("0")
                    i += 1
                } else if !(at(i + 1) == "C" && at(i + 2) == "H") {
                    key.append("T")
                }
            case "V":
                key.append("F")
            case "W", "Y":
                if isVowel(i + 1) { key.append(c) }
            case "X":
                key.append("KS")
            case "Z":
                key.append("S")
            default:
                key.append(c)
            }
            i += 1
        }
        return key
    }
}

/// Loads your contacts in the background and keeps them current.
final class ContactsIndex: @unchecked Sendable {
    static let shared = ContactsIndex()

    private let lock = NSLock()
    private var loaded: [People.Person] = []
    private var mine: [String] = []
    private var observer: NSObjectProtocol?

    var people: [People.Person] { lock.withLock { loaded } }
    /// The email addresses on your own card, the one Contacts marks as you.
    var ownEmails: [String] { lock.withLock { mine } }

    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Asks for Contacts access if needed, then loads. Returns whether access is granted.
    @discardableResult
    func enable() async -> Bool {
        if !Self.isAuthorized {
            let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            guard granted else { return false }
        }
        reload()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { [weak self] _ in
                self?.reload()
            }
        }
        return true
    }

    /// Reads every contact's name, nickname, and email addresses, off the main thread.
    func reload() {
        guard Self.isAuthorized else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let store = CNContactStore()
            // Only names: other people's email addresses are never read.
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
            var people: [People.Person] = []
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let person = People.Person(given: contact.givenName, family: contact.familyName, nickname: contact.nickname)
                if !person.name.isEmpty { people.append(person) }
            }
            let me = try? store.unifiedMeContactWithKeys(toFetch: [CNContactEmailAddressesKey as CNKeyDescriptor])
            let ownEmails = me?.emailAddresses.map { String($0.value) } ?? []
            self.lock.withLock {
                self.loaded = people
                self.mine = ownEmails
            }
        }
    }
}
