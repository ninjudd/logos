import Foundation
import Testing
@testable import Logos

@Suite struct PeopleTests {
    private typealias Person = People.Person
    private let jonathan = Person(given: "Jonathan", family: "Grubb", nickname: "", emails: ["jonathan@example.com"])
    private let will = Person(given: "Will", family: "Turner", nickname: "", emails: ["will@example.com"])
    private let theodore = Person(given: "Theodore", family: "Park", nickname: "Teddy", emails: [])
    private let kristin = Person(given: "Kristin", family: "Hale", nickname: "", emails: [])
    private let jonas = Person(given: "Jonas", family: "Lind", nickname: "", emails: [])

    private func names(_ transcript: String, _ people: [Person]) -> [String] {
        People.mentioned(in: transcript, among: people).map(\.name)
    }

    @Test func fullNameMatches() {
        #expect(names("Send the deck to Jonathan Grubb tomorrow.", [will, jonathan]) == ["Jonathan Grubb"])
    }

    // Catches a speech model's near miss, "Grub" for "Grubb", leaving the name unmatched.
    @Test func soundAlikeNameMatches() {
        #expect(names("Email Jonathan Grub the notes.", [jonathan]) == ["Jonathan Grubb"])
        #expect(names("Tell Kirsten the plan.", [kristin]) == ["Kristin Hale"])
    }

    // Catches the short form people say, "Jon", missing the contact's first name.
    @Test func capitalizedShortFormOfAFirstNameMatches() {
        #expect(names("Then ask Jon about the release.", [jonathan, theodore]) == ["Jonathan Grubb"])
    }

    // Catches surnames matching as short forms, which would let "Park" pull in "Parker".
    @Test func surnamesHaveNoShortForms() {
        let parker = Person(given: "Ann", family: "Parker", nickname: "", emails: [])
        #expect(names("We met near the Park entrance.", [parker]).isEmpty)
    }

    @Test func nicknameMatches() {
        #expect(names("Tell Teddy I'm running late.", [theodore]) == ["Theodore Park"])
    }

    // Catches everyday lowercase words bringing in contacts.
    @Test func lowercaseCommonWordsAloneDontMatch() {
        #expect(names("I think we will ship the fix today.", [will, theodore]).isEmpty)
    }

    // Catches "Will you…" at the start of a sentence sending Will Turner.
    @Test func shortNameStartingASentenceDoesntMatch() {
        #expect(names("Will you send the notes? Sure.", [will]).isEmpty)
        #expect(names("Jonathan said yes.", [jonathan]) == ["Jonathan Grubb"])
    }

    // Catches a first-name-only match outranking the person named in full.
    @Test func fullNameRanksAboveFirstNameOnly() {
        let jonathanLind = Person(given: "Jonathan", family: "Lind", nickname: "", emails: [])
        #expect(names("Yes, Jonathan Grubb and Jonas agreed.", [jonathanLind, jonas, jonathan]).first == "Jonathan Grubb")
    }

    // Catches a single name like "Alex" sending everyone named Alex.
    @Test func singleNameMatchesAreCapped() {
        let alexes = (1...8).map { Person(given: "Alex", family: "Person\($0)", nickname: "", emails: []) }
        #expect(People.mentioned(in: "Then Alex said hi.", among: alexes).count == People.singleNameLimit)
    }

    @Test func emailMentions() {
        #expect(People.mentionsEmail("Send it to Jon's email address"))
        #expect(People.mentionsEmail("what's your e-mail"))
        #expect(!People.mentionsEmail("Send it to Jon"))
    }

    // Catches other people's email addresses leaving the Mac by default.
    @Test func hintSendsNamesOnlyByDefault() throws {
        let hint = try #require(People.hint(for: [jonathan], includeTheirEmails: false, ownEmails: []))
        #expect(hint.text.contains("Jonathan Grubb"))
        #expect(!hint.text.contains("@"))
    }

    @Test func hintIncludesTheirEmailsWhenAllowed() throws {
        let hint = try #require(People.hint(for: [jonathan, theodore], includeTheirEmails: true, ownEmails: []))
        #expect(hint.text.contains("Jonathan Grubb (jonathan@example.com); Theodore Park"))
    }

    @Test func hintIncludesYourOwnEmails() throws {
        let hint = try #require(People.hint(for: [], includeTheirEmails: false, ownEmails: ["me@example.com"]))
        #expect(hint.text == "The speaker's own email addresses: me@example.com.")
        #expect(People.hint(for: [], includeTheirEmails: true, ownEmails: []) == nil)
    }

    // Published reference values for Jaro-Winkler.
    @Test func jaroWinkler() {
        #expect(abs(People.jaroWinkler("martha", "marhta") - 0.961) < 0.001)
        #expect(abs(People.jaroWinkler("dixon", "dicksonx") - 0.813) < 0.001)
        #expect(People.jaroWinkler("same", "same") == 1)
        #expect(People.jaroWinkler("abc", "xyz") == 0)
    }

    @Test func metaphoneKeys() {
        #expect(People.metaphone("Grubb") == People.metaphone("Grub"))
        #expect(People.metaphone("Kristin") == People.metaphone("Kirsten"))
        #expect(People.metaphone("Smith") == People.metaphone("Smyth"))
        #expect(People.metaphone("John") == People.metaphone("Jon"))
        #expect(People.metaphone("Ghostty") == People.metaphone("Ghosti"))
        #expect(People.metaphone("Grubb") != People.metaphone("Turner"))
    }

    @Test func offByDefault() throws {
        let config = try Config.decode(Data("{}".utf8))
        #expect(config.useContacts == false)
        #expect(config.shareContactEmails == false)
    }
}
