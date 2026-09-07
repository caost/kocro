import Foundation

struct TokenEntry: Equatable {
    let canonical: String
    let aliases: Set<String>
    let key: ShortcutKey

    func matches(_ token: String) -> Bool {
        let value = token.uppercased()
        return value == canonical || aliases.contains(value)
    }
}

enum KeyInputMode: CaseIterable {
    case shortcut
    case trailing
}

enum MacKeyCodePolicy {
    static let supportedFunctionNumbers = 1...20
    static let standaloneFunctionNumbers = 13...supportedFunctionNumbers.upperBound
    // 과거 저장 형식의 마이그레이션 대상이므로 현재 지원 범위와 별도로 유지한다.
    static let removedLegacyFunctionNumbers = 21...24

    static func shortcutRequiresModifiers(_ key: ShortcutKey) -> Bool {
        guard case .function(let number) = key else { return true }
        return !standaloneFunctionNumbers.contains(number)
    }

    private static let letterKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6,
        "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static let characterKeys: Set<UInt16> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50,
        93, 94,
    ]

    private static let editingAndNavigationKeys: Set<UInt16> = [
        36, 48, 49, 51, 53,
        114, 115, 116, 117, 119, 121, 123, 124, 125, 126,
    ]

    private static let shortcutEditingKeys = editingAndNavigationKeys.subtracting([51, 53, 117])

    private static let keypadKeys: Set<UInt16> = [
        65, 67, 69, 71, 75, 76, 78, 81,
        82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95,
    ]

    private static let functionNumbersByKeyCode: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
        98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18,
        80: 19, 90: 20,
    ]

    private static let functionKeyCodesByNumber: [Int: UInt16] = Dictionary(
        uniqueKeysWithValues: functionNumbersByKeyCode.map { ($0.value, $0.key) }
    )

    static func isAllowedShortcutKeyCode(_ keyCode: UInt16) -> Bool {
        characterKeys.contains(keyCode)
            || shortcutEditingKeys.contains(keyCode)
            || keypadKeys.contains(keyCode)
    }

    static func isAllowedTrailingKeyCode(_ keyCode: UInt16) -> Bool {
        characterKeys.contains(keyCode)
            || editingAndNavigationKeys.contains(keyCode)
            || keypadKeys.contains(keyCode)
            || functionNumbersByKeyCode[keyCode] != nil
    }

    static func functionNumber(for keyCode: UInt16) -> Int? {
        functionNumbersByKeyCode[keyCode]
    }

    static func keyCode(forFunction number: Int) -> UInt16? {
        functionKeyCodesByNumber[number]
    }

    static func keyCode(forLetter letter: String) -> UInt16? {
        letterKeyCodes[letter.lowercased()]
    }

    static func displayName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    static func tokenEntries(mode: KeyInputMode) -> [TokenEntry] {
        var keyCodes = characterKeys
            .union(keypadKeys)
            .union(mode == .shortcut ? shortcutEditingKeys : editingAndNavigationKeys)
        if mode == .trailing {
            keyCodes.formUnion(functionNumbersByKeyCode.keys)
        }

        var entries = keyCodes.compactMap { keyCode -> TokenEntry? in
            if let number = functionNumbersByKeyCode[keyCode] {
                return TokenEntry(
                    canonical: "{KC_F\(number)}",
                    aliases: [],
                    key: .function(number)
                )
            }
            guard let tokenName = tokenNames[keyCode] else { return nil }
            return TokenEntry(
                canonical: "{KC_\(tokenName)}",
                aliases: [],
                key: .keyCode(keyCode)
            )
        }
        if mode == .shortcut {
            entries.append(contentsOf: supportedFunctionNumbers.map { number in
                TokenEntry(
                    canonical: "{KC_F\(number)}",
                    aliases: [],
                    key: .function(number)
                )
            })
        }
        return Dictionary(grouping: entries, by: \.canonical)
            .compactMap(\.value.first)
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Backspace",
        53: "Escape", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +",
        71: "Keypad Clear", 75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -",
        81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
        85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 93: "Yen",
        94: "_", 95: "Keypad ,", 114: "Help", 115: "Home", 116: "Page Up",
        117: "Delete", 119: "End", 121: "Page Down", 123: "Left Arrow",
        124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]

    private static let tokenNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 10: "NUHS", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "EQUAL", 25: "9", 26: "7",
        27: "MINUS", 28: "8", 29: "0", 30: "RBRC", 31: "O", 32: "U",
        33: "LBRC", 34: "I", 35: "P", 36: "ENTER", 37: "L", 38: "J",
        39: "QUOT", 40: "K", 41: "SCLN", 42: "BSLS", 43: "COMM", 44: "SLSH",
        45: "N", 46: "M", 47: "DOT", 48: "TAB", 49: "SPACE", 50: "GRV",
        51: "BSPC", 53: "ESC", 65: "KP_DOT", 67: "KP_ASTERISK", 69: "KP_PLUS",
        71: "KP_CLEAR", 75: "KP_SLASH", 76: "KP_ENTER", 78: "KP_MINUS",
        81: "KP_EQUAL", 82: "KP_0", 83: "KP_1", 84: "KP_2", 85: "KP_3",
        86: "KP_4", 87: "KP_5", 88: "KP_6", 89: "KP_7", 91: "KP_8",
        92: "KP_9", 93: "JYEN", 94: "RO", 95: "KP_COMMA", 114: "HELP",
        115: "HOME", 116: "PGUP", 117: "DEL", 119: "END", 121: "PGDN",
        123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP",
    ]
}
