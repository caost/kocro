import Foundation

enum MacKeyCodePolicy {
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
            || editingAndNavigationKeys.contains(keyCode)
            || keypadKeys.contains(keyCode)
    }

    static func isAllowedTrailingKeyCode(_ keyCode: UInt16) -> Bool {
        isAllowedShortcutKeyCode(keyCode) || functionNumbersByKeyCode[keyCode] != nil
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
}
