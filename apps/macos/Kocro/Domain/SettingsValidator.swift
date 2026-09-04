import Foundation

enum ValidationError: Error {
    case duplicateID
    case textTooLong
    case emptyText
    case emptyShortcut
    case modifierRequired
    case unsupportedFunction
    case unsupportedModifiers
    case hidOnlyKeyRejectsModifiers
    case duplicateShortcut
    case invalidTrailing
}

struct SettingsValidator {
    func validate(_ settings: AppSettings) throws -> AppSettings {
        for macro in settings.macros {
            if let issue = issues(for: macro, in: settings).first {
                throw issue
            }
        }
        return settings
    }

    /// 한 항목이 어긋난 규칙을 모두 모은다. 저장 검증과 설정 화면의 항목별 표시가
    /// 같은 규칙을 두 벌로 구현하지 않도록 이 함수 하나만 사용한다.
    func issues(for macro: MacroDefinition, in settings: AppSettings) -> [ValidationError] {
        var issues: [ValidationError] = []

        if settings.macros.filter({ $0.id == macro.id }).count > 1 {
            issues.append(.duplicateID)
        }
        if macro.text.count > MacroDefinition.maximumTextCount {
            issues.append(.textTooLong)
        }
        guard macro.isEnabled else {
            return issues
        }
        if let trailingKey = macro.trailingKey,
           !thrownIssue({ try validateTrailing(trailingKey) }).isEmpty {
            issues.append(.invalidTrailing)
        }
        if macro.text.isEmpty {
            issues.append(.emptyText)
        }
        issues.append(contentsOf: thrownIssue { try validateShortcut(macro.shortcut) })

        guard let identity = macro.shortcut.registrationIdentity else {
            issues.append(.duplicateShortcut)
            return issues
        }
        let sharing = settings.macros.filter {
            $0.isEnabled && $0.shortcut.registrationIdentity == identity
        }
        if sharing.count > 1 {
            issues.append(.duplicateShortcut)
        }
        return issues
    }

    private func thrownIssue(_ body: () throws -> Void) -> [ValidationError] {
        do {
            try body()
            return []
        } catch let error as ValidationError {
            return [error]
        } catch {
            return [.invalidTrailing]
        }
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
                throw ValidationError.hidOnlyKeyRejectsModifiers
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
