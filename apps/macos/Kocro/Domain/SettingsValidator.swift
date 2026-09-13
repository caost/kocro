import Foundation

enum ValidationError: Error {
    case duplicateID
    case textTooLong
    case emptyText
    case emptyShortcut
    case modifierRequired
    case unsupportedFunction
    case unsupportedModifiers
    case reservedShortcut
    case duplicateShortcut
    case invalidTrailing
    case invalidDelay
    case invalidKeyCombination
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

    /// 저장 검증과 설정 화면에서 같은 규칙을 사용한다.
    func issues(for macro: MacroDefinition, in settings: AppSettings) -> [ValidationError] {
        var issues: [ValidationError] = []
        if settings.macros.filter({ $0.id == macro.id }).count > 1 {
            issues.append(.duplicateID)
        }
        if macro.combinedTextCount > MacroDefinition.maximumTextCount {
            issues.append(.textTooLong)
        }
        if macro.steps.contains(where: { step in
            if case .delay(let milliseconds) = step.kind {
                return !MacroStep.delayRange.contains(milliseconds)
            }
            return false
        }) {
            issues.append(.invalidDelay)
        }
        if macro.steps.contains(where: { step in
            if case .keys(let combination) = step.kind { return !combination.isValid }
            return false
        }) {
            issues.append(.invalidKeyCombination)
        }
        if macro.shortcut.usesRemovedFunctionKey {
            issues.append(.unsupportedFunction)
        }
        guard macro.isEnabled else { return issues }
        if !macro.steps.contains(where: \.isEmitting) {
            issues.append(.emptyText)
        }
        if !macro.shortcut.usesRemovedFunctionKey {
            issues.append(contentsOf: thrownIssue { try validateShortcut(macro.shortcut) })
        }
        guard let identity = macro.shortcut.registrationIdentity else {
            issues.append(.duplicateShortcut)
            return issues
        }
        let sharing = settings.macros.filter {
            $0.isEnabled && $0.shortcut.registrationIdentity == identity
        }
        if sharing.count > 1 { issues.append(.duplicateShortcut) }
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
            guard MacKeyCodePolicy.supportedFunctionNumbers.contains(number) else {
                throw ValidationError.unsupportedFunction
            }
            if MacKeyCodePolicy.shortcutRequiresModifiers(shortcut.key), shortcut.modifiers.isEmpty {
                throw ValidationError.modifierRequired
            }
        }
        if ReservedShortcutPolicy.contains(shortcut) {
            throw ValidationError.reservedShortcut
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

enum ReservedShortcutPolicy {
    /// AppKit 앱의 편집·파일·윈도우 메뉴에서 공통으로 쓰는 Command 단축키다.
    /// 앱별 단축키까지 추측해 막지 않도록 보조 키가 정확히 Command일 때만 적용한다.
    private static let commandKeyCodes: Set<UInt16> = [
        0,  // A: 전체 선택
        1,  // S: 저장
        3,  // F: 찾기
        4,  // H: 가리기
        5,  // G: 다음 찾기
        6,  // Z: 실행 취소
        7,  // X: 오려두기
        8,  // C: 복사
        9,  // V: 붙여넣기
        12, // Q: 종료
        13, // W: 윈도우 닫기
        31, // O: 열기
        35, // P: 프린트
        43, // comma: 설정
        45, // N: 새 문서
        46, // M: 최소화
    ]

    static func contains(_ shortcut: ShortcutDefinition) -> Bool {
        guard shortcut.modifiers == .command,
              let identity = shortcut.registrationIdentity else {
            return false
        }
        return commandKeyCodes.contains(identity.keyCode)
    }
}
