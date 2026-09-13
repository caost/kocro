import XCTest
@testable import Kocro

final class SettingsValidatorTests: XCTestCase {
    let validator = SettingsValidator()

    func testRejectsCommonCommandShortcutsBeforeCarbonRegistration() {
        let reservedKeys: [UInt16] = [0, 1, 3, 4, 5, 6, 7, 8, 9, 12, 13, 31, 35, 43, 45, 46]
        for keyCode in reservedKeys {
            XCTAssertThrowsError(try validator.validateShortcut(.init(key: .keyCode(keyCode), modifiers: .command))) { error in
                guard case ValidationError.reservedShortcut = error else {
                    return XCTFail("expected reservedShortcut, got \(error)")
                }
            }
        }
        XCTAssertNoThrow(try validator.validateShortcut(.init(key: .keyCode(8), modifiers: [.control, .option])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .letter("c"), modifiers: .command)))
    }

    func testDefaultsAndValidationExcludeF21ThroughF24ExecutionShortcuts() {
        XCTAssertEqual(AppSettings.defaults.macros.map(\.shortcut.key), (13...20).map { .function($0) })
        for number in 21...24 {
            XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(number), modifiers: [])))
            var inactive = MacroDefinition.newDraft()
            inactive.shortcut = .init(key: .function(number), modifiers: [])
            XCTAssertThrowsError(try validator.validate(.init(macros: [inactive])))
        }
    }

    func testDefaultsAndOrder() throws {
        let value = AppSettings.defaults
        XCTAssertEqual(value.macros.map(\.shortcut.key), (13...20).map { .function($0) })
        XCTAssertEqual(value.macros.map(\.title), (1...8).map { "매크로 \($0)" })
        XCTAssertEqual(Set(value.macros.map(\.id)).count, 8)
        XCTAssertTrue(value.macros.allSatisfy { !$0.isEnabled && $0.steps.isEmpty })
        XCTAssertNoThrow(try validator.validate(value))
        let reversed = AppSettings(macros: Array(value.macros.reversed()))
        XCTAssertEqual(try validator.validate(reversed).macros.map(\.id), Array(value.macros.reversed()).map(\.id))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(reversed))
        XCTAssertEqual(decoded, reversed)
    }

    func testDisplayTitleFallsBackOnlyForTheEmptyString() {
        XCTAssertEqual(Fixtures.macro(title: "", text: "x").displayTitle, "이름 없는 매크로")
        XCTAssertEqual(Fixtures.macro(title: "   ", text: "x").displayTitle, "   ")
        XCTAssertEqual(Fixtures.macro(title: " 제목 ", text: "x").displayTitle, " 제목 ")
    }

    func testIdentityLengthAndEnabledValues() {
        let shortcut = ShortcutDefinition(key: .function(13), modifiers: [])
        let valid = MacroDefinition(id: UUID(), isEnabled: true, shortcut: shortcut, text: "가", trailingKey: .enter)
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid, valid])))
        let duplicateShortcut = MacroDefinition(id: UUID(), isEnabled: true, shortcut: shortcut, text: "나", trailingKey: nil)
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid, duplicateShortcut])))
        XCTAssertThrowsError(try validator.validate(.init(macros: [valid.withText(String(repeating: "x", count: 10_001))])))
        XCTAssertNoThrow(try validator.validate(.init(macros: [valid.withText(String(repeating: "👨‍👩‍👧‍👦", count: 10_000))])))
        // Removing text still leaves an emitting Enter key step.
        XCTAssertNoThrow(try validator.validate(.init(macros: [valid.withText("")])))
        var empty = valid
        empty.steps = []
        XCTAssertEqual(validator.issues(for: empty, in: .init(macros: [empty])), [.emptyText])
    }

    func testDuplicateShortcutUsesCanonicalRegistrationIdentity() {
        let values = ["b", "B"].map { letter in
            MacroDefinition(id: UUID(), isEnabled: true, shortcut: .init(key: .letter(letter), modifiers: .command), text: "x", trailingKey: nil)
        } + [MacroDefinition(id: UUID(), isEnabled: true, shortcut: .init(key: .keyCode(11), modifiers: .command), text: "x", trailingKey: nil)]
        XCTAssertThrowsError(try validator.validate(.init(macros: values))) { error in
            guard case ValidationError.duplicateShortcut = error else {
                return XCTFail("expected duplicateShortcut, got \(error)")
            }
        }
    }

    func testRegistrationIdentityRejectsUnsupportedModifierBits() {
        let unsupported = ModifierSet(rawValue: ModifierSet.command.rawValue | 0x10)
        XCTAssertNil(ShortcutDefinition(key: .keyCode(0), modifiers: unsupported).registrationIdentity)
    }

    func testShortcutMatrixAndDuplicates() {
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .letter("a"), modifiers: [])))
        XCTAssertNoThrow(try validator.validateShortcut(.init(key: .letter("b"), modifiers: [.command])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .letter("1"), modifiers: [.command])))
        XCTAssertNoThrow(try validator.validateShortcut(.init(key: .keyCode(0), modifiers: [.control])))
        XCTAssertNoThrow(try validator.validateShortcut(.init(key: .function(1), modifiers: [.command])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(1), modifiers: [])))
        for number in 13...20 {
            XCTAssertNoThrow(try validator.validateShortcut(.init(key: .function(number), modifiers: [])))
            XCTAssertNoThrow(try validator.validateShortcut(.init(key: .function(number), modifiers: [.shift])))
        }
        for number in 21...35 {
            XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(number), modifiers: [])))
            XCTAssertThrowsError(try validator.validateShortcut(.init(key: .function(number), modifiers: [.shift])))
        }
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .letter("ab"), modifiers: [.command])))
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .keyCode(55), modifiers: [.command])))
        let unsupported = ModifierSet(rawValue: ModifierSet.command.rawValue | 0x10)
        XCTAssertThrowsError(try validator.validateShortcut(.init(key: .keyCode(0), modifiers: unsupported)))
    }

    func testTrailingKeyMatrix() {
        XCTAssertNoThrow(try validator.validateTrailing(.enter))
        XCTAssertNoThrow(try validator.validateTrailing(.space))
        XCTAssertNoThrow(try validator.validateTrailing(.tab))
        XCTAssertNoThrow(try validator.validateTrailing(.custom(keyCode: 0, modifiers: [.shift])))
        XCTAssertThrowsError(try validator.validateTrailing(.custom(keyCode: nil, modifiers: [.option])))
        XCTAssertThrowsError(try validator.validateTrailing(.custom(keyCode: 56, modifiers: [])))
        XCTAssertThrowsError(try validator.validateTrailing(.custom(keyCode: 0, modifiers: ModifierSet(rawValue: 0x10))))
        for number in 21...35 {
            XCTAssertThrowsError(try validator.validateTrailing(.customFunction(number)))
        }
    }

    func testRawKeyPolicyRejectsVolumeKeysAndAcceptsEveryKeypadDigit() {
        for volumeKeyCode: UInt16 in [72, 73, 74] {
            XCTAssertThrowsError(try validator.validateShortcut(.init(key: .keyCode(volumeKeyCode), modifiers: .command)))
            XCTAssertThrowsError(try validator.validateTrailing(.custom(keyCode: volumeKeyCode, modifiers: [])))
        }
        let keypadDigits: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for keyCode in keypadDigits {
            XCTAssertNoThrow(try validator.validateShortcut(.init(key: .keyCode(keyCode), modifiers: .control)))
            XCTAssertNoThrow(try validator.validateTrailing(.custom(keyCode: keyCode, modifiers: [])))
        }
    }

    func testRawKeyPolicyAcceptsStableJISKeys() {
        for keyCode: UInt16 in [93, 94, 95] {
            XCTAssertNoThrow(try validator.validateShortcut(.init(key: .keyCode(keyCode), modifiers: .command)))
            XCTAssertNoThrow(try validator.validateTrailing(.custom(keyCode: keyCode, modifiers: [])))
        }
    }

    func testInactiveDraftsAllowEmptyAndDuplicateShortcuts() {
        let settings = AppSettings(macros: (0..<100).map { _ in MacroDefinition.newDraft() })
        XCTAssertNoThrow(try validator.validate(settings))
    }

    func testDelayBoundsApplyToEnabledAndInactiveMacros() {
        for enabled in [false, true] {
            for milliseconds in [-1, 0, 60_000, 60_001] {
                var macro = Fixtures.carbon(13)
                macro.isEnabled = enabled
                macro.steps.append(.init(kind: .delay(milliseconds: milliseconds)))
                let issues = validator.issues(for: macro, in: .init(macros: [macro]))
                XCTAssertEqual(issues, (milliseconds == -1 || milliseconds == 60_001) ? [.invalidDelay] : [])
            }
        }
    }

    func testKeyCombinationPolicyAppliesToEnabledAndInactiveMacros() {
        let valid: [KeyCombination] = [
            .init(keyCode: 8, modifiers: .command),
            .init(keyCode: 36, modifiers: []),
            .init(keyCode: 53, modifiers: []),
            .init(keyCode: 51, modifiers: []),
            .init(keyCode: 117, modifiers: []),
            .init(keyCode: 95, modifiers: .supported),
        ]
        let invalid: [KeyCombination] = [
            .init(keyCode: 55, modifiers: []),
            .init(keyCode: 72, modifiers: []),
            .init(keyCode: UInt16.max, modifiers: []),
            .init(keyCode: 8, modifiers: .init(rawValue: 0x10)),
            .init(keyCode: 8, modifiers: .init(rawValue: 0x11)),
        ]
        for enabled in [false, true] {
            for combination in valid + invalid {
                var macro = Fixtures.carbon(13)
                macro.isEnabled = enabled
                macro.steps = [.init(kind: .keys(combination))]
                XCTAssertEqual(validator.issues(for: macro, in: .init(macros: [macro])),
                               invalid.contains(combination) ? [.invalidKeyCombination] : [])
            }
        }
    }

    func testTextLimitSumsGraphemeCountsAcrossSteps() {
        var macro = Fixtures.carbon(13)
        macro.steps = [
            .init(kind: .text(String(repeating: "👨🏽‍💻", count: 5_000))),
            .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
            .init(kind: .delay(milliseconds: 500)),
            .init(kind: .text(String(repeating: "e\u{301}", count: 5_000))),
        ]
        XCTAssertEqual(macro.combinedTextCount, 10_000)
        XCTAssertNoThrow(try validator.validate(.init(macros: [macro])))
        macro.steps.append(.init(kind: .text("가")))
        XCTAssertEqual(macro.combinedTextCount, 10_001)
        for enabled in [false, true] {
            macro.isEnabled = enabled
            XCTAssertEqual(validator.issues(for: macro, in: .init(macros: [macro])), [.textTooLong])
        }
    }

    func testEnabledSequenceRequiresEmittingStep() {
        let nonEmitting: [[MacroStep]] = [
            [], [.init(kind: .text(""))], [.init(kind: .delay(milliseconds: 500))],
            [.init(kind: .text("")), .init(kind: .delay(milliseconds: 0))],
        ]
        for steps in nonEmitting {
            var macro = Fixtures.carbon(13)
            macro.steps = steps
            XCTAssertEqual(validator.issues(for: macro, in: .init(macros: [macro])), [.emptyText])
            macro.isEnabled = false
            XCTAssertNoThrow(try validator.validate(.init(macros: [macro])))
            macro.isEnabled = true
            macro.steps.append(.init(kind: .keys(.init(keyCode: 9, modifiers: .command))))
            XCTAssertNoThrow(try validator.validate(.init(macros: [macro])))
        }
    }
}
