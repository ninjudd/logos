import Foundation
import Testing
@testable import Logos

@Suite struct FocusedFieldTests {
    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"])
    func textRolesTakeText(role: String) {
        #expect(FocusedField.acceptsText(.element(role: role, selectionSettable: false, inEditableArea: false)) == true)
    }

    // Catches a dictation shown in a card instead of pasted into a custom text
    // view, such as a terminal's, that reports a generic role.
    @Test func settableSelectionTakesText() {
        #expect(FocusedField.acceptsText(.element(role: "AXGroup", selectionSettable: true, inEditableArea: false)) == true)
    }

    // Catches contenteditable web editors, which report the role of the element
    // inside them rather than a text role.
    @Test func editableWebContentTakesText() {
        #expect(FocusedField.acceptsText(.element(role: "AXStaticText", selectionSettable: false, inEditableArea: true)) == true)
    }

    @Test func buttonDoesNotTakeText() {
        #expect(FocusedField.acceptsText(.element(role: "AXButton", selectionSettable: false, inEditableArea: false)) == false)
    }

    // The desktop, or an app window with nothing focused.
    @Test func noFocusDoesNotTakeText() {
        #expect(FocusedField.acceptsText(.none) == false)
    }

    // Catches showing a card, instead of pasting, whenever Accessibility can't
    // answer, which would break pasting into apps it doesn't understand.
    @Test func unknownFocusIsUndecided() {
        #expect(FocusedField.acceptsText(.unknown) == nil)
    }

    @Test func cardIsOnByDefaultWithNoExceptions() throws {
        let config = try Config.decode(Data("{}".utf8))
        #expect(config.showWhenNoTextField)
        #expect(config.alwaysPasteApps.isEmpty)
    }
}
