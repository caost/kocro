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

    var usesRemovedFunctionKey: Bool {
        guard case .function(let number) = key else { return false }
        return (21...24).contains(number)
    }

    var displayName: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }

        return prefix + (baseKeyName ?? "설정 안 됨")
    }

    var tokens: [String] {
        var values: [String] = []
        if modifiers.contains(.control) { values.append("⌃ Control") }
        if modifiers.contains(.option) { values.append("⌥ Option") }
        if modifiers.contains(.shift) { values.append("⇧ Shift") }
        if modifiers.contains(.command) { values.append("⌘ Command") }

        if let baseKeyName { values.append(baseKeyName) }
        return values
    }

    private var baseKeyName: String? {
        switch key {
        case .empty:
            return nil
        case .letter(let letter):
            return letter.uppercased()
        case .keyCode(let keyCode):
            return MacKeyCodePolicy.displayName(for: keyCode)
        case .function(let number):
            return "F\(number)"
        }
    }

    var registrationIdentity: ShortcutRegistrationIdentity? {
        guard modifiers.rawValue & ~ModifierSet.supported.rawValue == 0 else {
            return nil
        }
        let registrationKey: ShortcutRegistrationKey
        switch key {
        case .empty:
            return nil
        case .letter(let letter):
            guard let keyCode = MacKeyCodePolicy.keyCode(forLetter: letter) else {
                return nil
            }
            registrationKey = .carbon(keyCode)
        case .keyCode(let keyCode):
            registrationKey = .carbon(keyCode)
        case .function(let number) where (1...20).contains(number):
            guard let keyCode = MacKeyCodePolicy.keyCode(forFunction: number) else {
                return nil
            }
            registrationKey = .carbon(keyCode)
        case .function:
            return nil
        }
        return ShortcutRegistrationIdentity(
            key: registrationKey,
            modifiers: modifiers
        )
    }
}

enum ShortcutRegistrationKey: Hashable, Sendable {
    case carbon(UInt16)
}

struct ShortcutRegistrationIdentity: Hashable, Sendable {
    let key: ShortcutRegistrationKey
    let modifiers: ModifierSet
}

enum TrailingKey: Codable, Hashable, Sendable {
    case enter
    case space
    case tab
    case custom(keyCode: UInt16?, modifiers: ModifierSet)
    case customFunction(Int)
}

extension ShortcutDefinition {
    init(trailingKey: TrailingKey?) {
        guard case .custom(let keyCode?, let modifiers) = trailingKey else {
            self.init(key: .empty, modifiers: [])
            return
        }
        if let number = MacKeyCodePolicy.functionNumber(for: keyCode) {
            self.init(key: .function(number), modifiers: modifiers)
        } else {
            self.init(key: .keyCode(keyCode), modifiers: modifiers)
        }
    }
}

struct MacroDefinition: Codable, Equatable, Identifiable, Sendable {
    static let maximumTextCount = 10_000

    /// 화면과 오류 메시지가 함께 쓰는 상한 표기다. 실행 로케일과 무관하게 `10,000`을 낸다.
    static let maximumTextCountText = maximumTextCount.formatted(
        .number.grouping(.automatic).locale(Locale(identifier: "en_US"))
    )

    let id: UUID
    var title: String = ""
    var isEnabled: Bool
    var shortcut: ShortcutDefinition
    var text: String
    var trailingKey: TrailingKey?

    var displayTitle: String {
        title.isEmpty ? "이름 없는 매크로" : title
    }

    var settingsDisplayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).first ?? ""
        let value = String(firstLine.prefix(10))
        if value.isEmpty { return "새 매크로" }
        return firstLine.count > 10 ? value + "…" : value
    }

    static func newDraft() -> Self {
        Self(
            id: UUID(),
            title: "",
            isEnabled: false,
            shortcut: .init(key: .empty, modifiers: []),
            text: "",
            trailingKey: nil
        )
    }

    func withText(_ value: String) -> Self {
        var copy = self
        copy.text = value
        return copy
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var macros: [MacroDefinition]

    static let defaults = Self(
        macros: (13...20).enumerated().map { index, functionNumber in
            MacroDefinition(
                id: UUID(),
                title: "매크로 \(index + 1)",
                isEnabled: false,
                shortcut: ShortcutDefinition(key: .function(functionNumber), modifiers: []),
                text: "",
                trailingKey: nil
            )
        }
    )
}
