import Foundation
import Testing
@testable import Logos

@Suite struct PeopleTests {
    private typealias Person = People.Person
    private let jonathan = Person(name: "Jonathan Grubb", nickname: "", emails: ["jonathan@example.com"])
    private let will = Person(name: "Will Turner", nickname: "", emails: ["will@example.com"])
    private let theodore = Person(name: "Theodore Park", nickname: "Teddy", emails: [])
    private let jonas = Person(name: "Jonas Lind", nickname: "", emails: [])

    private func names(_ transcript: String, _ people: [Person]) -> [String] {
        People.mentioned(in: transcript, among: people).map(\.name)
    }

    @Test func fullNameMatches() {
        #expect(names("Send the deck to Jonathan Grubb tomorrow.", [will, jonathan]) == ["Jonathan Grubb"])
    }

    // Catches a speech model's near miss, "Grub" for "Grubb", leaving the name unmatched.
    @Test func misspelledNameMatches() {
        #expect(names("Email Jonathan Grub the notes.", [jonathan]) == ["Jonathan Grubb"])
    }

    // Catches the short form people say, "Jon", missing the contact's full name.
    @Test func capitalizedShortFormMatches() {
        #expect(names("Ask Jon about the release.", [jonathan, theodore]) == ["Jonathan Grubb"])
    }

    @Test func nicknameMatches() {
        #expect(names("Tell Teddy I'm running late.", [theodore]) == ["Theodore Park"])
    }

    // Catches everyday lowercase words bringing in contacts, which would send
    // their email addresses to the cleanup model for no reason.
    @Test func lowercaseCommonWordsAloneDontMatch() {
        #expect(names("I think we will ship the fix today.", [will, theodore]).isEmpty)
    }

    // Catches a first-name-only match outranking the person named in full.
    @Test func fullNameRanksAboveFirstNameOnly() {
        let jonathanLind = Person(name: "Jonathan Lind", nickname: "", emails: [])
        #expect(names("Jonathan Grubb and Jonas said yes.", [jonathanLind, jonas, jonathan]).first == "Jonathan Grubb")
    }

    @Test func atMostFiveComeBack() {
        let many = (1...8).map { Person(name: "Alex Person\($0)", nickname: "", emails: []) }
        #expect(People.mentioned(in: "Alex said hi.", among: many).count == People.limit)
    }

    @Test func hintListsNamesAndEmails() throws {
        let hint = try #require(People.hint(for: [jonathan, theodore]))
        #expect(hint.source == "your contacts")
        #expect(hint.text.hasSuffix("Jonathan Grubb (jonathan@example.com); Theodore Park"))
        #expect(People.hint(for: []) == nil)
    }

    @Test func distance() {
        #expect(People.distance("grubb", "grub") == 1)
        #expect(People.distance("kitten", "sitting") == 3)
        #expect(People.distance("", "abc") == 3)
        #expect(People.distance("same", "same") == 0)
    }

    @Test func offByDefault() throws {
        #expect(try Config.decode(Data("{}".utf8)).useContacts == false)
    }
}
