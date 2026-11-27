import Contacts
import Foundation

/// Your contacts' names and email addresses, matched against each transcript on
/// your Mac. Only the people a dictation seems to mention, at most a handful,
/// reach the cleanup model, so it can spell their names and fill in their email
/// addresses.
enum People {
    struct Person: Equatable {
        var name: String
        var nickname: String
        var emails: [String]
    }

    /// The most people one dictation sends to the cleanup model.
    static let limit = 5

    /// The people `transcript` seems to mention, best match first. A name part
    /// matches a word in the transcript that is spelled the same, is off by a
    /// letter or two, or is a short form of it, such as "Jon" for "Jonathan".
    /// A person counts when two of their name parts match, or when one matches
    /// a capitalized word. Speech models capitalize names, so a lowercase word
    /// such as "will" or "the" alone doesn't bring in Will or Theodore.
    static func mentioned(in transcript: String, among people: [Person], limit: Int = People.limit) -> [Person] {
        let words = transcript.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        let all = Set(words.map { $0.lowercased() })
        let capitalized = Set(words.filter { $0.first?.isUppercase == true }.map { $0.lowercased() })
        guard !all.isEmpty else { return [] }
        let scored: [(person: Person, score: Int)] = people.compactMap { person in
            let parts = Set(tokens(person.name) + tokens(person.nickname)).filter { $0.count >= 3 }
            let matched = parts.filter { part in all.contains { close($0, part) } }
            let named = parts.contains { part in capitalized.contains { close($0, part) } }
            guard matched.count >= 2 || named else { return nil }
            return (person, matched.count * 2 + (named ? 1 : 0))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.person.name < $1.person.name }
            .prefix(limit)
            .map(\.person)
    }

    /// The hint for the cleanup prompt's {{context}}, or nil when nobody matched.
    static func hint(for people: [Person]) -> AppContext.Hint? {
        guard !people.isEmpty else { return nil }
        let list = people.map { person in
            person.emails.isEmpty ? person.name : "\(person.name) (\(person.emails.joined(separator: ", ")))"
        }.joined(separator: "; ")
        return AppContext.Hint(
            source: "your contacts",
            text: "People the transcript may mention. When it refers to one of them, spell the name as listed here, and use these email addresses when the speaker asks for one: \(list)")
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Whether a transcript word `word` could be the name part `part`.
    static func close(_ word: String, _ part: String) -> Bool {
        if word == part { return true }
        if part.hasPrefix(word) && word.count >= 3 && part.count - word.count <= 5 { return true }
        let longer = max(word.count, part.count)
        guard min(word.count, part.count) >= 4 else { return false }
        return distance(word, part) <= (longer >= 7 ? 2 : 1)
    }

    /// Levenshtein edit distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Loads your contacts in the background and keeps them current.
final class ContactsIndex: @unchecked Sendable {
    static let shared = ContactsIndex()

    private let lock = NSLock()
    private var loaded: [People.Person] = []
    private var observer: NSObjectProtocol?

    var people: [People.Person] { lock.withLock { loaded } }

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
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var people: [People.Person] = []
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                guard !name.isEmpty else { return }
                people.append(.init(name: name, nickname: contact.nickname,
                                    emails: contact.emailAddresses.map { String($0.value) }))
            }
            self.lock.withLock { self.loaded = people }
        }
    }
}
