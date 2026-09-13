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
        return MacKeyCodePolicy.removedLegacyFunctionNumbers.contains(number)
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
        case .empty: return nil
        case .letter(let letter): return letter.uppercased()
        case .keyCode(let keyCode): return MacKeyCodePolicy.displayName(for: keyCode)
        case .function(let number): return "F\(number)"
        }
    }

    var registrationIdentity: ShortcutRegistrationIdentity? {
        guard modifiers.rawValue & ~ModifierSet.supported.rawValue == 0 else { return nil }
        let registrationKeyCode: UInt16
        switch key {
        case .empty: return nil
        case .letter(let letter):
            guard let keyCode = MacKeyCodePolicy.keyCode(forLetter: letter) else { return nil }
            registrationKeyCode = keyCode
        case .keyCode(let keyCode):
            registrationKeyCode = keyCode
        case .function(let number):
            guard let keyCode = MacKeyCodePolicy.keyCode(forFunction: number) else { return nil }
            registrationKeyCode = keyCode
        }
        return .init(keyCode: registrationKeyCode, modifiers: modifiers)
    }
}

struct ShortcutRegistrationIdentity: Hashable, Sendable {
    let keyCode: UInt16
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

struct KeyCombination: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: ModifierSet

    init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(trailingKey: TrailingKey?) {
        switch trailingKey {
        case .enter?: self.init(keyCode: 36, modifiers: [])
        case .space?: self.init(keyCode: 49, modifiers: [])
        case .tab?: self.init(keyCode: 48, modifiers: [])
        case .custom(let code?, let flags)?: self.init(keyCode: code, modifiers: flags)
        case nil, .custom(nil, _)?, .customFunction?: return nil
        }
    }

    var trailingKey: TrailingKey { .custom(keyCode: keyCode, modifiers: modifiers) }
    var displayName: String { ShortcutDefinition(trailingKey: trailingKey).displayName }
    var isValid: Bool {
        MacKeyCodePolicy.isAllowedTrailingKeyCode(keyCode)
            && modifiers.isSubset(of: .supported)
    }
}

struct MacroStep: Codable, Hashable, Sendable, Identifiable {
    enum Kind: Codable, Hashable, Sendable {
        case text(String)
        case keys(KeyCombination)
        case delay(milliseconds: Int)
    }

    static let delayRange = 0...60_000
    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    var isEmitting: Bool {
        switch kind {
        case .text(let text): return !text.isEmpty
        case .keys: return true
        case .delay: return false
        }
    }

    var displayName: String {
        switch kind {
        case .text(let text): return text.isEmpty ? "빈 문자열" : "문자열: \(text.prefix(40))"
        case .keys(let combination): return "키 조합: \(combination.displayName)"
        case .delay(let milliseconds): return "대기 \(milliseconds)ms"
        }
    }

    static func legacySteps(text: String, trailingKey: TrailingKey?) -> [Self] {
        var steps: [Self] = text.isEmpty ? [] : [.init(kind: .text(text))]
        if let trailingKey {
            // 잘못된 레거시 값도 버리지 않고 검증 계층에서 거부하도록 유지한다.
            let combination = KeyCombination(trailingKey: trailingKey)
                ?? KeyCombination(keyCode: UInt16.max, modifiers: [])
            steps.append(.init(kind: .keys(combination)))
        }
        return steps
    }
}

struct MacroDefinition: Codable, Equatable, Identifiable, Sendable {
    static let maximumTextCount = 10_000
    static let maximumTextCountText = maximumTextCount.formatted(
        .number.grouping(.automatic).locale(Locale(identifier: "en_US"))
    )

    let id: UUID
    var title: String = ""
    var isEnabled: Bool
    var shortcut: ShortcutDefinition
    var steps: [MacroStep]

    init(id: UUID, title: String = "", isEnabled: Bool,
         shortcut: ShortcutDefinition, steps: [MacroStep]) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.steps = steps
    }

    init(id: UUID, title: String = "", isEnabled: Bool,
         shortcut: ShortcutDefinition, text: String, trailingKey: TrailingKey?) {
        self.init(id: id, title: title, isEnabled: isEnabled, shortcut: shortcut,
                  steps: MacroStep.legacySteps(text: text, trailingKey: trailingKey))
    }

    var combinedTextCount: Int {
        steps.reduce(0) { count, step in
            guard case .text(let text) = step.kind else { return count }
            return count + text.count
        }
    }

    var displayTitle: String { title.isEmpty ? "이름 없는 매크로" : title }

    var settingsDisplayTitle: String {
        if !title.isEmpty { return title }
        let text = steps.lazy.compactMap { step -> String? in
            guard case .text(let text) = step.kind else { return nil }
            return text
        }.first ?? ""
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let value = String(firstLine.prefix(10))
        if value.isEmpty { return "새 매크로" }
        return firstLine.count > 10 ? value + "…" : value
    }

    static func newDraft() -> Self {
        Self(id: UUID(), title: "", isEnabled: false,
             shortcut: .init(key: .empty, modifiers: []), steps: [])
    }

    func withText(_ value: String) -> Self {
        var copy = self
        if let index = copy.steps.firstIndex(where: {
            if case .text = $0.kind { return true }
            return false
        }) {
            copy.steps[index].kind = .text(value)
        } else {
            copy.steps.append(.init(kind: .text(value)))
        }
        return copy
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var macros: [MacroDefinition]

    static let defaults = Self(
        macros: MacKeyCodePolicy.standaloneFunctionNumbers.enumerated().map { index, functionNumber in
            MacroDefinition(id: UUID(), title: "매크로 \(index + 1)", isEnabled: false,
                            shortcut: .init(key: .function(functionNumber), modifiers: []),
                            steps: [])
        }
    )
}
