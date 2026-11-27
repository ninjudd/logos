import ApplicationServices

/// Asks Accessibility whether the focused element takes typed text, so a dictation
/// with nowhere to go can be shown instead of pasted into nothing.
enum FocusedField {
    /// What Accessibility reports about keyboard focus.
    enum Focus: Equatable {
        /// Nothing in the frontmost app has keyboard focus.
        case none
        case element(role: String?, selectionSettable: Bool, inEditableArea: Bool)
        /// Accessibility couldn't answer.
        case unknown
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Electron apps, and Chrome, build their accessibility tree only once an app
    /// asks for it. Logos asks when you press the hotkey, so the tree exists by
    /// the time it checks focus.
    static func prepare(pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// True when the focused element takes text, false when nothing could, and nil
    /// when Accessibility can't tell. Callers paste unless this is false, so an
    /// unrecognized field still gets its text.
    static func acceptsText(_ focus: Focus) -> Bool? {
        switch focus {
        case .unknown:
            return nil
        case .none:
            return false
        case .element(let role, let selectionSettable, let inEditableArea):
            if let role, textRoles.contains(role) { return true }
            // Custom text views and editable web content expose a text selection
            // or sit inside an editable region even when their role is generic.
            return selectionSettable || inEditableArea
        }
    }

    static func current() -> Focus {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) {
        case .success:
            break
        case .noValue:
            return .none
        default:
            return .unknown
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        let element = value as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var settable: DarwinBoolean = false
        let selectionSettable = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
        var ancestor: CFTypeRef?
        let inEditableArea = AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &ancestor) == .success
            && ancestor != nil
        return .element(role: role as? String, selectionSettable: selectionSettable, inEditableArea: inEditableArea)
    }
}
