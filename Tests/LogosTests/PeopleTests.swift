import Foundation
import Testing
@testable import Logos

@Suite struct PeopleTests {
    private typealias Person = People.Person
    private let jonathan = Person(given: "Jonathan", family: "Grubb", nickname: "")
    private let will = Person(given: "Will", family: "Turner", nickname: "")
    private let theodore = Person(given: "Theodore", family: "Park", nickname: "Teddy")
    private let kristin = Person(given: "Kristin", family: "Hale", nickname: "")
    private let jonas = Person(given: "Jonas", family: "Lind", nickname: "")

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
        let parker = Person(given: "Ann", family: "Parker", nickname: "")
        #expect(names("We met near the Park entrance.", [parker]).isEmpty)
    }

    @Test func nicknameMatches() {
        #expect(names("Tell Teddy I'm running late.", [theodore]) == ["Theodore Park"])
    }

    // Catches everyday lowercase words bringing in contacts.
    @Test func lowercaseCommonWordsAloneDontMatch() {
        #expect(names("I think we will ship the fix today.", [will, theodore]).isEmpty)
    }

    // Catches ordinary lowercase words that sound like a first and a last name,
    // anywhere in the transcript, sending a contact nobody mentioned.
    @Test func everydayWordsDontPairUpIntoAFullName() {
        let william = Person(given: "William", family: "Wright", nickname: "")
        let andrew = Person(given: "Andrew", family: "Hill", nickname: "")
        let candace = Person(given: "Candace", family: "White", nickname: "")
        let everyone = [william, andrew, candace]
        #expect(names("I will get it right this time.", everyone).isEmpty)
        #expect(names("Okay, I will write it up and say hello.", everyone).isEmpty)
        #expect(names("Can you tell me what happened?", everyone).isEmpty)
        #expect(names("Ask Will Wright, and say hello.", everyone) == ["William Wright"])
    }

    // Catches a transcript with no capitals losing a full name spelled exactly.
    @Test func lowercaseFullNameSpelledExactlyMatches() {
        #expect(names("send the notes to will turner", [will, jonathan]) == ["Will Turner"])
    }

    // Catches a last name matched far from the first name counting as a full
    // name, which escapes the cap on people resting on a single name.
    @Test func aLastNameFarFromTheFirstDoesntMakeAFullName() {
        let wright = Person(given: "Jonathan", family: "Wright", nickname: "")
        let lind = Person(given: "Jonathan", family: "Lind", nickname: "")
        #expect(names("Then ask Jon about it, right?", [wright, lind, jonathan]) == ["Jonathan Grubb", "Jonathan Lind"])
    }

    // Catches "Will you…" at the start of a sentence sending Will Turner.
    @Test func shortNameStartingASentenceDoesntMatch() {
        #expect(names("Will you send the notes? Sure.", [will]).isEmpty)
        #expect(names("Jonathan said yes.", [jonathan]) == ["Jonathan Grubb"])
    }

    // Catches a first-name-only match outranking the person named in full.
    @Test func fullNameRanksAboveFirstNameOnly() {
        let jonathanLind = Person(given: "Jonathan", family: "Lind", nickname: "")
        #expect(names("Yes, Jonathan Grubb and Jonas agreed.", [jonathanLind, jonas, jonathan]).first == "Jonathan Grubb")
    }

    // Catches a single name like "Alex" sending everyone named Alex.
    @Test func singleNameMatchesAreCapped() {
        let alexes = (1...8).map { Person(given: "Alex", family: "Person\($0)", nickname: "") }
        #expect(People.mentioned(in: "Then Alex said hi.", among: alexes).count == People.singleNameLimit)
    }

    @Test func emailMentions() {
        #expect(People.mentionsEmail("Send it to Jon's email address"))
        #expect(People.mentionsEmail("what's your e-mail"))
        #expect(People.mentionsEmail("Mail it to my Gmail"))
        #expect(!People.mentionsEmail("Send it to Jon"))
    }

    private func config(contacts: Bool = true, myEmails: Bool, extra: [String] = []) -> Config {
        var config = Config()
        config.useContacts = contacts
        config.includeMyEmails = myEmails
        config.myEmails = extra
        return config
    }

    private func hintTexts(_ transcript: String, _ config: Config, card: [String] = ["me@example.com"]) -> [String] {
        People.hints(for: transcript, config: config, people: [jonathan, theodore], cardEmails: card).map(\.text)
    }

    @Test func namesHintListsMatchedPeople() {
        #expect(hintTexts("Ask Jonathan Grubb.", config(myEmails: false))
            == ["People the transcript may mention. When it refers to one of them, spell the name as listed here: Jonathan Grubb."])
        #expect(hintTexts("Ask Jonathan Grubb.", config(contacts: false, myEmails: false)).isEmpty)
    }

    // Catches your own addresses going out without the setting.
    @Test func ownEmailsNeedTheSetting() {
        #expect(hintTexts("Send it to my email.", config(myEmails: false)).isEmpty)
    }

    @Test func ownEmailsGoWhenMailIsMentioned() {
        let on = config(myEmails: true, extra: ["Me@Example.com", "me@work.example"])
        #expect(hintTexts("Send it to my email.", on)
            == ["The speaker's own email addresses: me@example.com, me@work.example."])
        #expect(hintTexts("Send it to Theodore.", on).allSatisfy { !$0.contains("@") })
    }

    // Catches the card's addresses being used when contacts are off.
    @Test func cardEmailsNeedContacts() {
        let off = config(contacts: false, myEmails: true, extra: ["me@work.example"])
        #expect(hintTexts("Send it to my email.", off) == ["The speaker's own email addresses: me@work.example."])
        #expect(hintTexts("Send it to my email.", config(contacts: false, myEmails: true)).isEmpty)
    }

    @Test func parsesTypedAddresses() {
        #expect(People.parseEmails("a@x.example, b@y.example;c@z.example ") == ["a@x.example", "b@y.example", "c@z.example"])
        #expect(People.parseEmails(" , ").isEmpty)
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
        #expect(config.includeMyEmails == false)
        #expect(config.myEmails.isEmpty)
    }
}
