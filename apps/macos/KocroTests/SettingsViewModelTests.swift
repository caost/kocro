import AppKit
import XCTest
@testable import Kocro

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testSettingsStartsInMacrosSectionAndSupportsGeneralSelection() {
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())

        XCTAssertEqual(model.selectedSection, .macros)

        model.selectedSection = .general

        XCTAssertEqual(model.selectedSection, .general)
        XCTAssertEqual(SettingsSection.allCases, [.macros, .general])
    }

    func testRuntimeMacrosExposeSavedExecutionStateWithoutChangingIt() {
        let runtime = Fixtures.settings(text: "저장된 값")
        let app = AppController(
            store: StoreSpy(loadResult: .success(runtime)),
            shortcuts: ShortcutSpy(),
            permissions: PermissionSpy(),
            queue: QueueSpy()
        )

        app.start()
        app.draft.macros[0].text = "저장 전 편집"

        XCTAssertEqual(app.runtimeMacros, runtime.macros)
    }

    func testUnlimitedEditingSupportsThirtyItemsDeleteAndReorder() {
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())

        for _ in 0..<30 { model.add() }
        let last = model.settings.macros[29].id
        model.move(from: IndexSet(integer: 29), to: 0)
        model.delete(at: IndexSet(integer: 1))

        XCTAssertEqual(model.settings.macros.first?.id, last)
        XCTAssertEqual(model.settings.macros.count, 29)
        XCTAssertTrue(model.settings.macros.allSatisfy(\.title.isEmpty))
        XCTAssertTrue(model.isDirty)
    }

    func testTitleEditingStaysInDraftUntilSave() {
        let original = AppSettings(
            macros: [Fixtures.macro(title: "테스트 매크로", text: "값")]
        )
        let model = SettingsViewModel(settings: original, validator: .init())
        var saved: AppSettings?
        model.onSave = { saved = $0 }

        model.settings.macros[0].title = "편집한 제목"

        XCTAssertEqual(original.macros[0].title, "테스트 매크로")
        XCTAssertNil(saved)
        XCTAssertTrue(model.isDirty)

        model.save()

        XCTAssertEqual(saved?.macros[0].title, "편집한 제목")
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

    func testStatusSynchronizationReplacesCompleteRegistrationMapWithoutChangingDirtyDraft() {
        let original = Fixtures.settings(text: "저장된 값")
        let replacement = Fixtures.carbon(14)
        let shortcuts = ShortcutSpy(states: [original.macros[0].id: .registrationFailed])
        let app = AppController(
            store: StoreSpy(loadResult: .success(original)),
            shortcuts: shortcuts,
            permissions: PermissionSpy(),
            queue: QueueSpy()
        )
        app.start()
        let model = SettingsViewModel(settings: original, validator: .init())
        model.settings.macros[0].text = "저장 전 편집"
        model.synchronizeStatus(from: app)

        shortcuts.states = [replacement.id: .registered]
        app.draft = .init(macros: [replacement])
        app.save()
        model.synchronizeStatus(from: app)

        XCTAssertEqual(model.settings.macros[0].text, "저장 전 편집")
        XCTAssertEqual(model.registration, [replacement.id: .registered])
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

        XCTAssertEqual(model.settings.macros.count, 8)
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

    func testDisplayTitleUsesUserTitleThenFirstLineThenNewMacroWithoutMutation() {
        var macro = Fixtures.macro(title: "", text: "가나다라마바사아자차카\n둘째 줄")
        XCTAssertEqual(macro.settingsDisplayTitle, "가나다라마바사아자차…")
        XCTAssertEqual(macro.title, "")
        macro.text = "\n둘째 줄"
        XCTAssertEqual(macro.settingsDisplayTitle, "새 매크로")
        macro.title = "사용자 제목"
        XCTAssertEqual(macro.settingsDisplayTitle, "사용자 제목")
    }

    func testSettingsOwnsInvalidTokenDraftByUUIDAcrossRemoval() {
        let macro = Fixtures.carbon(13)
        let field = TokenField.shortcut(macro.id)
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )

        model.updateTokenText("{KC_NOPE}", for: field)
        model.delete(at: IndexSet(integer: 0))

        XCTAssertEqual(model.tokenDraft(for: field).text, "{KC_NOPE}")
        XCTAssertTrue(model.isDirty)
    }

    func testAccordionStartsCollapsedAndAddingExpandsOnlyNewMacro() {
        let model = SettingsViewModel(settings: Fixtures.settings(text: "값"), validator: .init())
        XCTAssertNil(model.expandedMacroID)
        model.add()
        XCTAssertEqual(model.expandedMacroID, model.settings.macros.last?.id)
        model.expand(model.settings.macros[0].id)
        XCTAssertEqual(model.expandedMacroID, model.settings.macros[0].id)
    }

    func testMultipleDeletesUndoNewestFirstAtOriginalPositions() {
        let values = [Fixtures.carbon(13), Fixtures.carbon(14), Fixtures.carbon(15)]
        let model = SettingsViewModel(settings: .init(macros: values), validator: .init())
        model.delete(id: values[1].id)
        model.delete(id: values[0].id)
        model.undoDelete()
        XCTAssertEqual(model.settings.macros.map(\.id), [values[0].id, values[2].id])
        model.undoDelete()
        XCTAssertEqual(model.settings.macros.map(\.id), values.map(\.id))
    }

    func testSaveSuccessClearsUndoAndCollapsesWhileFailureExpandsFirstError() {
        let invalid = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .empty, modifiers: []), text: "값", trailingKey: nil)
        let model = SettingsViewModel(settings: .init(macros: [invalid]), validator: .init())
        model.save()
        XCTAssertEqual(model.expandedMacroID, invalid.id)
        XCTAssertEqual(model.focusedField, .shortcut(invalid.id))
        model.settings.macros[0].isEnabled = false
        model.markSaved(model.settings)
        XCTAssertNil(model.expandedMacroID)
        XCTAssertFalse(model.canUndoDelete)
    }

    func testInactiveEmptyShortcutPassesTokenPreflightButActiveValidationFocusesIt() {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        XCTAssertTrue(model.prepareTokenEditsForSave())
        model.settings.macros[0].isEnabled = true
        model.save()
        XCTAssertEqual(model.expandedMacroID, macro.id)
        XCTAssertEqual(model.focusedField, .shortcut(macro.id))
        XCTAssertTrue(model.errors(for: macro.id).contains("단축키를 수정하세요"))
    }

    func testSettingsOwnsInvalidTokenDraftAcrossCollapseAndSavePreflight() {
        let macro = Fixtures.carbon(13)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        model.updateTokenText("{KC_NOPE}", for: .shortcut(macro.id))
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.badge(for: macro.id), .unsaved)
        XCTAssertEqual(model.collapsedShortcutText(for: macro.id), "{KC_NOPE}")
        model.expand(macro.id)
        model.expand(macro.id)
        XCTAssertEqual(model.tokenDraft(for: .shortcut(macro.id)).text, "{KC_NOPE}")
        model.save()
        XCTAssertEqual(model.expandedMacroID, macro.id)
        XCTAssertEqual(model.focusedField, .shortcut(macro.id))
    }

    func testCollapsedShortcutSplitsCanonicalTextIntoTokenBlocks() {
        let macro = MacroDefinition(
            id: UUID(),
            isEnabled: false,
            shortcut: .init(key: .keyCode(8), modifiers: .command),
            text: "",
            trailingKey: nil
        )
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )

        XCTAssertEqual(
            model.collapsedShortcutTokens(for: macro.id),
            ["{KC_CMD}", "{KC_C}"]
        )
    }

    func testCollapsedMaximumShortcutHasReadableAccessibilityValue() {
        let macro = MacroDefinition(
            id: UUID(),
            isEnabled: false,
            shortcut: .init(
                key: .keyCode(95),
                modifiers: [.control, .option, .shift, .command]
            ),
            text: "",
            trailingKey: nil
        )
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )

        XCTAssertEqual(model.collapsedShortcutTokens(for: macro.id).count, 5)
        XCTAssertEqual(
            model.collapsedShortcutAccessibilityValue(for: macro.id),
            "⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command, Keypad ,"
        )
    }

    func testCollapsedEmptyShortcutAccessibilityPresentationIsContextual() {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )

        let presentation = model.collapsedShortcutAccessibilityPresentation(
            for: macro.id
        )

        XCTAssertTrue(presentation.label.contains(macro.id.uuidString))
        XCTAssertEqual(presentation.value, "설정 안 됨")
    }

    func testCollapsedInvalidShortcutPreservesRawSeparators() {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )
        let values = [
            "+",
            "+{KC_C}",
            "{KC_CMD}+",
            "{KC_CMD}++{KC_C}",
        ]

        for value in values {
            model.updateTokenText(value, for: .shortcut(macro.id))

            XCTAssertEqual(model.collapsedShortcutTokens(for: macro.id), [value])
            XCTAssertEqual(
                model.collapsedShortcutAccessibilityValue(for: macro.id),
                "유효하지 않은 단축키, \(value)"
            )
        }
    }

    func testReservedShortcutShowsSpecificMessageAndFocusesShortcut() {
        let macro = MacroDefinition(
            id: UUID(),
            isEnabled: true,
            shortcut: .init(key: .keyCode(8), modifiers: [.control, .option]),
            text: "값",
            trailingKey: nil
        )
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )

        model.mutateTokenDraft(.shortcut(macro.id)) {
            $0.applyRecorded(.init(key: .keyCode(8), modifiers: .command))
        }

        XCTAssertTrue(model.errors(for: macro.id).contains("이미 사용 중인 단축키입니다"))

        model.save()

        XCTAssertTrue(model.errors(for: macro.id).contains("이미 사용 중인 단축키입니다"))
        XCTAssertEqual(model.expandedMacroID, macro.id)
        XCTAssertEqual(model.focusedField, .shortcut(macro.id))
    }

    func testSupportedKeyHelpCoversRequiredTopics() {
        let text = SupportedKeyHelp.sections.map(\.body).joined(separator: "\n")
        for required in ["실행 단축키", "후속 키", "별칭", "보조 키",
                         "F13~F20", "F21~F35", "지원하지"] {
            XCTAssertTrue(text.contains(required), "missing help topic: \(required)")
        }
        XCTAssertTrue(text.contains("Escape, Backspace와 Delete는 실행 단축키로 사용할 수 없습니다"))
        XCTAssertTrue(text.contains("Command만 사용하는 표준 단축키"))
    }

    func testCorruptSettingsWarningRemainsAboveTabsUntilSuccessfulSave() {
        let model = SettingsViewModel(settings: .defaults, validator: .init())
        model.showsReplaceWarning = true
        XCTAssertEqual(model.replaceWarningMessage,
            "저장하면 기존 설정 파일을 기본 설정으로 교체합니다.")
        model.saveErrorMessage = "설정을 저장하지 못했습니다"
        XCTAssertNotNil(model.replaceWarningMessage)
        model.markSaved(model.settings)
        model.showsReplaceWarning = false
        XCTAssertNil(model.replaceWarningMessage)
    }

    func testBadgePriorityCoversDirtyInactiveAndRegistrationFailures() {
        XCTAssertEqual(MacroStatusBadge.resolve(isEnabled: true, isDirty: true,
            registration: .registrationFailed).label, "등록 실패")
        XCTAssertEqual(MacroStatusBadge.resolve(isEnabled: false, isDirty: false,
            registration: .registrationFailed).label, "등록 실패")
        XCTAssertEqual(MacroStatusBadge.resolve(isEnabled: false, isDirty: false,
            registration: nil).label, "비활성")
    }

    func testInactiveRecordedReservedShortcutWarnsWithoutBlockingDraftSave() {
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())
        model.add()
        let id = model.settings.macros[0].id
        model.mutateTokenDraft(.shortcut(id)) {
            $0.applyRecorded(.init(key: .keyCode(8), modifiers: .command))
        }
        XCTAssertTrue(model.errors(for: id).contains("이미 사용 중인 단축키입니다"))
        var saved: AppSettings?
        model.onSave = { saved = $0 }
        model.save()
        XCTAssertEqual(saved?.macros[0].shortcut, .init(key: .keyCode(8), modifiers: .command))
        XCTAssertEqual(saved?.macros[0].isEnabled, false)
    }

    func testCardAccessibilityLabelsIncludeDistinctUUIDAndAction() throws {
        let first = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let second = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let one = MacroCardAccessibilityLabels(id: first)
        let two = MacroCardAccessibilityLabels(id: second)
        XCTAssertEqual(one.delete, "매크로 \(first.uuidString) 삭제")
        XCTAssertEqual(one.reorder, "매크로 \(first.uuidString) 순서 변경")
        XCTAssertNotEqual(one.expand, two.expand)
        XCTAssertNotEqual(one.title, one.enabled)
    }

    func testAccessibleMoveActionsReorderMacrosAndRespectBounds() {
        let values = [Fixtures.carbon(13), Fixtures.carbon(14), Fixtures.carbon(15)]
        let model = SettingsViewModel(settings: .init(macros: values), validator: .init())

        XCTAssertTrue(model.move(id: values[1].id, direction: .up))
        XCTAssertEqual(model.settings.macros.map(\.id), [values[1].id, values[0].id, values[2].id])
        XCTAssertFalse(model.move(id: values[1].id, direction: .up))
        XCTAssertTrue(model.move(id: values[1].id, direction: .down))
        XCTAssertEqual(model.settings.macros.map(\.id), values.map(\.id))
    }

    func testCollapsedHeaderSelectionExpandsWithoutTogglingExpandedCard() {
        let values = [Fixtures.carbon(13), Fixtures.carbon(14)]
        let model = SettingsViewModel(settings: .init(macros: values), validator: .init())

        model.selectHeader(values[0].id)
        XCTAssertEqual(model.expandedMacroID, values[0].id)
        model.selectHeader(values[0].id)
        XCTAssertEqual(model.expandedMacroID, values[0].id)
        model.selectHeader(values[1].id)
        XCTAssertEqual(model.expandedMacroID, values[1].id)
    }

    func testInactiveEmptyShortcutPassesTokenPreflight() {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(
            settings: .init(macros: [macro]),
            validator: .init()
        )

        XCTAssertTrue(model.prepareTokenEditsForSave())
        XCTAssertNoThrow(try model.validator.validate(model.settings))

        model.settings.macros[0].isEnabled = true

        XCTAssertThrowsError(try model.validator.validate(model.settings))
    }
}
