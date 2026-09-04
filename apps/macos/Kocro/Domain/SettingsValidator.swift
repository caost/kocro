import Foundation

enum ValidationError: Error {
    case duplicateID
    case textTooLong
    case emptyText
    case emptyShortcut
    case modifierRequired
    case unsupportedFunction
    case unsupportedModifiers
    case HIDModifiers
    case duplicateShortcut
    case invalidTrailing
}

struct SettingsValidator {
    func validate(_ settings: AppSettings) throws -> AppSettings {
        var identifiers = Set<UUID>()
        var activeShortcuts = Set<ShortcutRegistrationIdentity>()

        for macro in settings.macros {
            guard identifiers.insert(macro.id).inserted else {
                throw ValidationError.duplicateID
            }
            guard macro.text.count <= 10_000 else {
                throw ValidationError.textTooLong
            }
            guard macro.isEnabled else {
                continue
            }
            if let trailingKey = macro.trailingKey {
                try validateTrailing(trailingKey)
            }
            guard !macro.text.isEmpty else {
                throw ValidationError.emptyText
            }
            try validateShortcut(macro.shortcut)
            guard let identity = macro.shortcut.registrationIdentity,
                  activeShortcuts.insert(identity).inserted else {
                throw ValidationError.duplicateShortcut
            }
        }

        return settings
    }

    func validateShortcut(_ shortcut: ShortcutDefinition) throws {
        try validateModifiers(shortcut.modifiers)
        switch shortcut.key {
        case .empty:
            throw ValidationError.emptyShortcut
        case .letter(let letter):
            guard MacKeyCodePolicy.keyCode(forLetter: letter) != nil,
                  !shortcut.modifiers.isEmpty else {
                throw ValidationError.modifierRequired
            }
        case .keyCode(let keyCode):
            guard MacKeyCodePolicy.isAllowedShortcutKeyCode(keyCode),
                  !shortcut.modifiers.isEmpty else {
                throw ValidationError.modifierRequired
            }
        case .function(let number):
            guard (1...24).contains(number) else {
                throw ValidationError.unsupportedFunction
            }
            if number <= 12, shortcut.modifiers.isEmpty {
                throw ValidationError.modifierRequired
            }
            if (21...24).contains(number), !shortcut.modifiers.isEmpty {
                throw ValidationError.HIDModifiers
            }
        }
    }

    func validateTrailing(_ trailingKey: TrailingKey) throws {
        switch trailingKey {
        case .enter, .space, .tab:
            return
        case .custom(let keyCode?, let modifiers):
            try validateModifiers(modifiers)
            guard MacKeyCodePolicy.isAllowedTrailingKeyCode(keyCode) else {
                throw ValidationError.invalidTrailing
            }
        case .custom(nil, _), .customFunction:
            throw ValidationError.invalidTrailing
        }
    }

    private func validateModifiers(_ modifiers: ModifierSet) throws {
        guard modifiers.rawValue & ~ModifierSet.supported.rawValue == 0 else {
            throw ValidationError.unsupportedModifiers
        }
    }
}
