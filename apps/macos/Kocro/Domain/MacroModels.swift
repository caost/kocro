import Foundation

struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1)
    static let control = Self(rawValue: 2)
    static let option = Self(rawValue: 4)
    static let shift = Self(rawValue: 8)
    static let supported: Self = [.command, .control, .option, .shift]
}

enum ShortcutKey: Codable, Hashable, Sendable {
    case empty
    case letter(String)
    case keyCode(UInt16)
    case function(Int)
}

struct ShortcutDefinition: Codable, Hashable, Sendable {
    var key: ShortcutKey
    var modifiers: ModifierSet

    var isHIDOnly: Bool {
        if case .function(let number) = key {
            return (21...24).contains(number) && modifiers.isEmpty
        }
        return false
    }

    var functionNumber: Int? {
        if case .function(let number) = key {
            return number
        }
        return nil
    }

    var displayName: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }

        let keyName: String
        switch key {
        case .empty:
            keyName = "설정 안 됨"
        case .letter(let letter):
            keyName = letter.uppercased()
        case .keyCode(let keyCode):
            keyName = "Key \(keyCode)"
        case .function(let number):
            keyName = "F\(number)"
        }
        return prefix + keyName
    }
}

enum TrailingKey: Codable, Hashable, Sendable {
    case enter
    case space
    case tab
    case custom(keyCode: UInt16?, modifiers: ModifierSet)
    case customFunction(Int)
}

struct MacroDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var isEnabled: Bool
    var shortcut: ShortcutDefinition
    var text: String
    var trailingKey: TrailingKey?

    func withText(_ value: String) -> Self {
        var copy = self
        copy.text = value
        return copy
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var macros: [MacroDefinition]

    static let defaults = Self(
        macros: (13...24).map {
            MacroDefinition(
                id: UUID(),
                isEnabled: false,
                shortcut: ShortcutDefinition(key: .function($0), modifiers: []),
                text: "",
                trailingKey: nil
            )
        }
    )
}
