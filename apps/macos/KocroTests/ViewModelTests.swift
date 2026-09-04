import AppKit
import XCTest
@testable import Kocro

@MainActor
final class ViewModelTests: XCTestCase {
    func testStatusPriorityAndRegisteredCount() {
        let menu = MenuBarViewModel(
            statuses: [.inputMonitoringRequired, .accessibilityRequired, .settingsError],
            registrations: [.registered, .registrationFailed, .registered]
        )

        XCTAssertEqual(menu.statusText, "설정 오류")
        XCTAssertEqual(menu.registeredCount, 2)
        XCTAssertEqual(
            MenuBarViewModel(
                statuses: [.inputMonitoringRequired, .accessibilityRequired],
                registrations: []
            ).statusText,
            "Accessibility 권한 필요"
        )
    }

    func testUnlimitedEditingSupportsThirtyItemsDeleteAndReorder() {
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())

        for _ in 0..<30 { model.add() }
        let last = model.settings.macros[29].id
        model.move(from: IndexSet(integer: 29), to: 0)
        model.delete(at: IndexSet(integer: 1))

        XCTAssertEqual(model.settings.macros.first?.id, last)
        XCTAssertEqual(model.settings.macros.count, 29)
        XCTAssertTrue(model.isDirty)
    }

    func testErrorsAreScopedToMacroIDAndCountUnicodeCharacters() {
        let invalid = MacroDefinition(
            id: UUID(),
            isEnabled: true,
            shortcut: .init(key: .letter("a"), modifiers: []),
            text: String(repeating: "👨🏽‍💻", count: 10_001),
            trailingKey: nil
        )
        let valid = Fixtures.macro(text: "한글\ne\u{301}")
        let model = SettingsViewModel(
            settings: .init(macros: [invalid, valid]),
            validator: .init()
        )

        XCTAssertEqual(model.characterCount(for: invalid.id), 10_001)
        XCTAssertTrue(model.errors(for: invalid.id).contains("문자열은 10,000자 이하여야 합니다"))
        XCTAssertTrue(model.errors(for: invalid.id).contains("단축키를 수정하세요"))
        XCTAssertTrue(model.errors(for: valid.id).isEmpty)
    }

    func testErrorsUseCanonicalShortcutIdentityAndIgnoreInactiveTrailingDraft() {
        let first = MacroDefinition(
            id: UUID(),
            isEnabled: true,
            shortcut: .init(key: .letter("A"), modifiers: .command),
            text: "x",
            trailingKey: nil
        )
        let second = MacroDefinition(
            id: UUID(),
            isEnabled: true,
            shortcut: .init(key: .keyCode(0), modifiers: .command),
            text: "y",
            trailingKey: nil
        )
        let inactive = MacroDefinition(
            id: UUID(),
            isEnabled: false,
            shortcut: .init(key: .empty, modifiers: []),
            text: "",
            trailingKey: .custom(keyCode: nil, modifiers: [])
        )
        let model = SettingsViewModel(
            settings: .init(macros: [first, second, inactive]),
            validator: .init()
        )

        XCTAssertTrue(model.errors(for: first.id).contains("활성 단축키가 중복됩니다"))
        XCTAssertTrue(model.errors(for: second.id).contains("활성 단축키가 중복됩니다"))
        XCTAssertTrue(model.errors(for: inactive.id).isEmpty)
    }

    func testStatusSynchronizationDoesNotOverwriteDirtyDraft() {
        let original = Fixtures.settings(text: "저장된 값")
        let app = AppController(
            store: StoreSpy(loadResult: .success(original)),
            shortcuts: ShortcutSpy(states: [original.macros[0].id: .registrationFailed]),
            permissions: PermissionSpy(),
            queue: QueueSpy()
        )
        app.start()
        let model = SettingsViewModel(settings: original, validator: .init())
        model.settings.macros[0].text = "저장 전 편집"

        model.synchronizeStatus(from: app)

        XCTAssertEqual(model.settings.macros[0].text, "저장 전 편집")
        XCTAssertEqual(model.registration[original.macros[0].id], .registrationFailed)
        XCTAssertTrue(model.isDirty)
    }

    func testBadLoadDraftIsReplacedWithDefaultsOnlyWhenSettingsOpen() {
        let app = AppController(
            store: StoreSpy(loadResult: .failure(StoreError.invalidFile)),
            shortcuts: ShortcutSpy(),
            permissions: PermissionSpy(),
            queue: QueueSpy()
        )
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())
        app.start()
        model.loadDraftIfNeeded(from: app)
        XCTAssertTrue(model.settings.macros.isEmpty)

        app.prepareSettingsDraft()
        model.loadDraftIfNeeded(from: app)
        model.synchronizeStatus(from: app)

        XCTAssertEqual(model.settings.macros.count, 12)
        XCTAssertTrue(model.showsReplaceWarning)
        XCTAssertFalse(model.isDirty)
    }

    func testInvalidSaveDoesNotInvokeSaveHandlerAndKeepsDirtyDraft() {
        let macro = MacroDefinition(
            id: UUID(),
            isEnabled: true,
            shortcut: .init(key: .empty, modifiers: []),
            text: "값",
            trailingKey: nil
        )
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )
        var saved: AppSettings?
        model.onSave = { saved = $0 }

        model.save()

        XCTAssertNil(saved)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.saveErrorMessage, "표시된 항목을 수정한 뒤 다시 저장하세요")
    }

    func testLocalKeyRecorderEnforcesFunctionKeyRules() {
        XCTAssertEqual(
            KeyRecorderTranslator.shortcut(keyCode: 105, modifiers: []),
            ShortcutDefinition(key: .function(13), modifiers: [])
        )
        XCTAssertNil(KeyRecorderTranslator.shortcut(keyCode: 122, modifiers: []))
        XCTAssertNil(KeyRecorderTranslator.shortcut(keyCode: 110, modifiers: []))
        XCTAssertNil(KeyRecorderTranslator.shortcut(keyCode: 0, modifiers: []))
        XCTAssertEqual(
            KeyRecorderTranslator.shortcut(keyCode: 0, modifiers: [.command]),
            ShortcutDefinition(key: .keyCode(0), modifiers: .command)
        )
    }

    func testTrailingKeyRecorderAllowsPlainKeysButRejectsUnsupportedFunctionKeys() {
        XCTAssertEqual(
            KeyRecorderTranslator.trailingKey(keyCode: 0, modifiers: []),
            TrailingKey.custom(keyCode: 0, modifiers: [])
        )
        XCTAssertEqual(
            KeyRecorderTranslator.trailingKey(keyCode: 90, modifiers: [.shift]),
            TrailingKey.custom(keyCode: 90, modifiers: .shift)
        )
        XCTAssertNil(KeyRecorderTranslator.trailingKey(keyCode: 110, modifiers: []))
    }

    func testShortcutDisplayIncludesModifiersWithoutUsingTypedText() {
        XCTAssertEqual(
            ShortcutDefinition(
                key: .function(13),
                modifiers: [.control, .option, .shift, .command]
            ).displayName,
            "⌃⌥⇧⌘F13"
        )
        XCTAssertEqual(
            ShortcutDefinition(key: .keyCode(0), modifiers: .command).displayName,
            "⌘Key 0"
        )
    }

    func testRecorderUsesRawKeyPolicyForVolumeAndKeypadKeys() {
        for volumeKeyCode: UInt16 in [72, 73, 74] {
            XCTAssertNil(
                KeyRecorderTranslator.shortcut(
                    keyCode: volumeKeyCode,
                    modifiers: .command
                )
            )
            XCTAssertNil(
                KeyRecorderTranslator.trailingKey(
                    keyCode: volumeKeyCode,
                    modifiers: []
                )
            )
        }

        let keypadDigits: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for keyCode in keypadDigits {
            XCTAssertEqual(
                KeyRecorderTranslator.shortcut(keyCode: keyCode, modifiers: .command),
                ShortcutDefinition(key: .keyCode(keyCode), modifiers: .command)
            )
            XCTAssertEqual(
                KeyRecorderTranslator.trailingKey(keyCode: keyCode, modifiers: []),
                TrailingKey.custom(keyCode: keyCode, modifiers: [])
            )
        }

        XCTAssertEqual(
            KeyRecorderTranslator.shortcut(keyCode: 90, modifiers: []),
            ShortcutDefinition(key: .function(20), modifiers: [])
        )
    }

    func testRecorderAcceptsStableJISKeysForShortcutsAndTrailingKeys() {
        for keyCode: UInt16 in [93, 94, 95] {
            XCTAssertEqual(
                KeyRecorderTranslator.shortcut(keyCode: keyCode, modifiers: .option),
                ShortcutDefinition(key: .keyCode(keyCode), modifiers: .option)
            )
            XCTAssertEqual(
                KeyRecorderTranslator.trailingKey(keyCode: keyCode, modifiers: []),
                TrailingKey.custom(keyCode: keyCode, modifiers: [])
            )
        }
    }
}
