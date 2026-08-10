import AppKit

public struct ExtensionShortcut: Codable, Equatable, Sendable {
    public let key: String           // Web event.key name: "G", "R", "F2", etc.
    public let modifiers: [String]   // Web modifier names: "Alt", "Shift", "Control", "Meta"

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

// MARK: - Display Formatting

extension ExtensionShortcut {
    /// Formats as symbol string for UI display: "⌥⇧G"
    public var displayString: String {
        let symbolMap: [String: String] = [
            "Meta": "⌘",
            "Control": "⌃",
            "Alt": "⌥",
            "Shift": "⇧",
        ]
        // Fixed order: Control, Alt, Shift, Meta, then key
        let orderedModifiers = ["Control", "Alt", "Shift", "Meta"]
        let symbols = orderedModifiers
            .filter { modifiers.contains($0) }
            .compactMap { symbolMap[$0] }
        return symbols.joined() + key.uppercased()
    }

}

// MARK: - NSEvent Conversion

extension ExtensionShortcut {
    /// Creates an ExtensionShortcut from an NSEvent key press.
    /// Returns nil if no valid key could be extracted.
    public static func from(event: NSEvent) -> ExtensionShortcut? {
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
              !characters.isEmpty else { return nil }

        // Map special keys
        let key: String
        switch event.keyCode {
        case 122: key = "F1"
        case 120: key = "F2"
        case 99:  key = "F3"
        case 118: key = "F4"
        case 96:  key = "F5"
        case 97:  key = "F6"
        case 98:  key = "F7"
        case 100: key = "F8"
        case 101: key = "F9"
        case 109: key = "F10"
        case 103: key = "F11"
        case 111: key = "F12"
        default:  key = characters
        }

        var modifiers: [String] = []
        if event.modifierFlags.contains(.control) { modifiers.append("Control") }
        if event.modifierFlags.contains(.option)  { modifiers.append("Alt") }
        if event.modifierFlags.contains(.shift)   { modifiers.append("Shift") }
        if event.modifierFlags.contains(.command) { modifiers.append("Meta") }

        return ExtensionShortcut(key: key, modifiers: modifiers)
    }

    /// Validates that the shortcut has at least one modifier key
    public var isValid: Bool {
        !key.isEmpty && !modifiers.isEmpty
    }

    /// Carbon virtual key code for conflict detection with KeyboardShortcuts library.
    /// Maps web key names to macOS Carbon key codes (kVK_ANSI_* values).
    public var carbonKeyCode: Int? {
        let map: [String: Int] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
            "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
            "Y": 16, "T": 17, "O": 31, "U": 32, "I": 34, "P": 35,
            "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
            "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        ]
        return map[key.uppercased()]
    }
}

// MARK: - Defaults

extension ExtensionShortcut {
    public static let defaultGrabElement = ExtensionShortcut(key: "G", modifiers: ["Alt", "Shift"])
    public static let defaultRegionSelect = ExtensionShortcut(key: "R", modifiers: ["Alt", "Shift"])
}
