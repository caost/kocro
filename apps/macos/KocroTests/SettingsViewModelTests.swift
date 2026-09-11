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
        let app = AppController(store: StoreSpy(loadResult: .success(runtime)),
            shortcuts: ShortcutSpy(), permissions: PermissionSpy(), queue: QueueSpy())
        app.start()
        app.draft.macros[0] = app.draft.macros[0].withText("저장 전 편집")
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
        let original = AppSettings(macros: [Fixtures.macro(title: "테스트 매크로", text: "값")])
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
        let invalid = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .letter("a"), modifiers: []),
            text: String(repeating: "👨🏽‍💻", count: 10_001), trailingKey: nil)
        let valid = Fixtures.macro(text: "한글\ne\u{301}")
        let model = SettingsViewModel(settings: .init(macros: [invalid, valid]), validator: .init())
        XCTAssertEqual(model.characterCount(for: invalid.id), 10_001)
        XCTAssertTrue(model.errors(for: invalid.id).contains("문자열은 10,000자 이하여야 합니다"))
        XCTAssertTrue(model.errors(for: invalid.id).contains("단축키를 수정하세요"))
        XCTAssertTrue(model.errors(for: valid.id).isEmpty)
    }

    func testErrorsUseCanonicalShortcutIdentityAndValidateInactiveKeySteps() {
        let first = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .letter("A"), modifiers: .command), text: "x", trailingKey: nil)
        let second = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .keyCode(0), modifiers: .command), text: "y", trailingKey: nil)
        let inactive = MacroDefinition(id: UUID(), isEnabled: false,
            shortcut: .init(key: .empty, modifiers: []),
            steps: [.init(kind: .keys(.init(keyCode: UInt16.max, modifiers: [])))])
        let model = SettingsViewModel(settings: .init(macros: [first, second, inactive]), validator: .init())
        XCTAssertTrue(model.errors(for: first.id).contains("활성 단축키가 중복됩니다"))
        XCTAssertTrue(model.errors(for: second.id).contains("활성 단축키가 중복됩니다"))
        XCTAssertTrue(model.errors(for: inactive.id).contains("키 조합을 수정하세요"))
    }

    func testStatusSynchronizationDoesNotOverwriteDirtyDraft() {
        let original = Fixtures.settings(text: "저장된 값")
        let app = AppController(store: StoreSpy(loadResult: .success(original)),
            shortcuts: ShortcutSpy(states: [original.macros[0].id: .registrationFailed]),
            permissions: PermissionSpy(), queue: QueueSpy())
        app.start()
        let model = SettingsViewModel(settings: original, validator: .init())
        model.settings.macros[0] = model.settings.macros[0].withText("저장 전 편집")
        model.synchronizeStatus(from: app)
        XCTAssertEqual(model.settings.macros[0].steps.map(\.kind), [.text("저장 전 편집")])
        XCTAssertEqual(model.registration[original.macros[0].id], .registrationFailed)
        XCTAssertTrue(model.isDirty)
    }

    func testStatusSynchronizationReplacesCompleteRegistrationMapWithoutChangingDirtyDraft() {
        let original = Fixtures.settings(text: "저장된 값")
        let replacement = Fixtures.carbon(14)
        let shortcuts = ShortcutSpy(states: [original.macros[0].id: .registrationFailed])
        let app = AppController(store: StoreSpy(loadResult: .success(original)),
            shortcuts: shortcuts, permissions: PermissionSpy(), queue: QueueSpy())
        app.start()
        let model = SettingsViewModel(settings: original, validator: .init())
        model.settings.macros[0] = model.settings.macros[0].withText("저장 전 편집")
        model.synchronizeStatus(from: app)
        shortcuts.states = [replacement.id: .registered]
        app.draft = .init(macros: [replacement])
        app.save()
        model.synchronizeStatus(from: app)
        XCTAssertEqual(model.settings.macros[0].steps.map(\.kind), [.text("저장 전 편집")])
        XCTAssertEqual(model.registration, [replacement.id: .registered])
        XCTAssertTrue(model.isDirty)
    }

    func testBadLoadDraftIsReplacedWithDefaultsOnlyWhenSettingsOpen() {
        let app = AppController(store: StoreSpy(loadResult: .failure(StoreError.invalidFile)),
            shortcuts: ShortcutSpy(), permissions: PermissionSpy(), queue: QueueSpy())
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
        let macro = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .empty, modifiers: []), text: "값", trailingKey: nil)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
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
        macro = macro.withText("\n둘째 줄")
        XCTAssertEqual(macro.settingsDisplayTitle, "새 매크로")
        macro.title = "사용자 제목"
        XCTAssertEqual(macro.settingsDisplayTitle, "사용자 제목")
    }

    func testSettingsOwnsInvalidTokenDraftByUUIDAcrossRemoval() {
        let macro = Fixtures.carbon(13)
        let field = TokenField.shortcut(macro.id)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
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
        let macro = MacroDefinition(id: UUID(), isEnabled: false,
            shortcut: .init(key: .keyCode(8), modifiers: .command), text: "", trailingKey: nil)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        XCTAssertEqual(model.collapsedShortcutTokens(for: macro.id), ["{KC_CMD}", "{KC_C}"])
    }

    func testCollapsedMaximumShortcutHasReadableAccessibilityValue() {
        let macro = MacroDefinition(id: UUID(), isEnabled: false,
            shortcut: .init(key: .keyCode(95), modifiers: [.control, .option, .shift, .command]),
            text: "", trailingKey: nil)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        XCTAssertEqual(model.collapsedShortcutTokens(for: macro.id).count, 5)
        XCTAssertEqual(model.collapsedShortcutAccessibilityValue(for: macro.id),
            "⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command, Keypad ,")
    }

    func testCollapsedEmptyShortcutAccessibilityPresentationIsContextual() {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        let presentation = model.collapsedShortcutAccessibilityPresentation(for: macro.id)
        XCTAssertTrue(presentation.label.contains(macro.id.uuidString))
        XCTAssertEqual(presentation.value, "설정 안 됨")
    }

    func testCollapsedInvalidShortcutPreservesRawSeparators() {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        for value in ["+", "+{KC_C}", "{KC_CMD}+", "{KC_CMD}++{KC_C}"] {
            model.updateTokenText(value, for: .shortcut(macro.id))
            XCTAssertEqual(model.collapsedShortcutTokens(for: macro.id), [value])
            XCTAssertEqual(model.collapsedShortcutAccessibilityValue(for: macro.id), "유효하지 않은 단축키, \(value)")
        }
    }

    func testReservedShortcutShowsSpecificMessageAndFocusesShortcut() {
        let macro = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .keyCode(8), modifiers: [.control, .option]), text: "값", trailingKey: nil)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
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
        for required in ["실행 단축키", "후속 키", "별칭", "보조 키", "F13~F20", "F21~F35", "지원하지"] {
            XCTAssertTrue(text.contains(required), "missing help topic: \(required)")
        }
        XCTAssertTrue(text.contains("Escape, Backspace와 Delete는 실행 단축키로 사용할 수 없습니다"))
        XCTAssertTrue(text.contains("Command만 사용하는 표준 단축키"))
    }

    func testCorruptSettingsWarningRemainsAboveTabsUntilSuccessfulSave() {
        let model = SettingsViewModel(settings: .defaults, validator: .init())
        model.showsReplaceWarning = true
        XCTAssertEqual(model.replaceWarningMessage, "저장하면 기존 설정 파일을 기본 설정으로 교체합니다.")
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
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        XCTAssertTrue(model.prepareTokenEditsForSave())
        XCTAssertNoThrow(try model.validator.validate(model.settings))
        model.settings.macros[0].isEnabled = true
        XCTAssertThrowsError(try model.validator.validate(model.settings))
    }

    func testStepAddMoveDeletePreservesIDsAndRemovesDeletedDraft() throws {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        let textID = try XCTUnwrap(model.addTextStep(macroID: macro.id))
        let keyID = try XCTUnwrap(model.addKeyStep(macroID: macro.id))
        let delayID = try XCTUnwrap(model.addDelayStep(macroID: macro.id))
        XCTAssertEqual(model.settings.macros[0].steps.map(\.kind), [
            .text(""), .keys(.init(keyCode: 36, modifiers: [])), .delay(milliseconds: 500)])
        XCTAssertEqual(model.expandedMacroID, macro.id)
        XCTAssertEqual(model.focusedField, .step(macroID: macro.id, stepID: delayID))
        XCTAssertFalse(model.moveStep(id: textID, direction: .up))
        XCTAssertFalse(model.moveStep(id: delayID, direction: .down))
        XCTAssertTrue(model.moveStep(id: delayID, direction: .up))
        XCTAssertEqual(model.settings.macros[0].steps.map(\.id), [textID, delayID, keyID])
        let field = TokenField.step(macroID: macro.id, stepID: keyID)
        model.updateTokenText("{KC_NOPE}", for: field)
        model.focusedField = field.focus
        model.deleteStep(macroID: macro.id, stepID: keyID)
        XCTAssertNil(model.tokenDrafts[field])
        XCTAssertNil(model.focusedField)
        XCTAssertEqual(model.settings.macros[0].steps.map(\.id), [textID, delayID])
        XCTAssertTrue(model.prepareTokenEditsForSave())
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.badge(for: macro.id), .unsaved)
        XCTAssertFalse(model.moveStep(id: keyID, direction: .up))
    }

    func testStepDraftCommitPreservesOrderAndSavedSnapshot() throws {
        let original = Fixtures.settings(text: "저장된 문자열")
        let macroID = original.macros[0].id
        let model = SettingsViewModel(settings: original, validator: .init())
        let keyID = try XCTUnwrap(model.addKeyStep(macroID: macroID))
        let delayID = try XCTUnwrap(model.addDelayStep(macroID: macroID))
        let field = TokenField.step(macroID: macroID, stepID: keyID)
        model.updateTokenText("{KC_C}+{KC_LCMD}", for: field)
        model.updateDelay(milliseconds: 750, macroID: macroID, stepID: delayID)
        XCTAssertTrue(model.moveStep(id: keyID, direction: .up))
        XCTAssertTrue(model.moveStep(id: delayID, direction: .up))
        XCTAssertEqual(original.macros[0].steps.map(\.kind), [.text("저장된 문자열")])
        var saved: AppSettings?
        model.onSave = { saved = $0 }
        model.save()
        let value = try XCTUnwrap(saved)
        XCTAssertEqual(value.macros[0].steps.map(\.id), [keyID, delayID, original.macros[0].steps[0].id])
        XCTAssertEqual(value.macros[0].steps.map(\.kind), [
            .keys(.init(keyCode: 8, modifiers: .command)), .delay(milliseconds: 750), .text("저장된 문자열")])
        XCTAssertEqual(model.tokenDraft(for: field).text, "{KC_CMD}+{KC_C}")
        model.markSaved(value)
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.expandedMacroID)
        model.updateTokenText("{KC_CMD}+{KC_V}", for: field)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.badge(for: macroID), .unsaved)
        XCTAssertEqual(value.macros[0].steps[0].kind, .keys(.init(keyCode: 8, modifiers: .command)))
    }

    func testInvalidKeyDraftBlocksSaveAndFocusesStepWithoutPartialCommit() throws {
        let macro = MacroDefinition(id: UUID(), isEnabled: true,
            shortcut: .init(key: .function(13), modifiers: []), steps: [
                .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
                .init(kind: .keys(.init(keyCode: 9, modifiers: .command)))])
        let original = AppSettings(macros: [macro])
        let model = SettingsViewModel(settings: original, validator: .init())
        let first = TokenField.step(macroID: macro.id, stepID: macro.steps[0].id)
        let second = TokenField.step(macroID: macro.id, stepID: macro.steps[1].id)
        model.updateTokenText("{KC_F14}", for: .shortcut(macro.id))
        model.updateTokenText("{KC_CMD}+{KC_X}", for: first)
        model.updateTokenText("{KC_NOPE}", for: second)
        model.expand(macro.id)
        model.expand(macro.id)
        var saved: AppSettings?
        model.onSave = { saved = $0 }
        model.save()
        XCTAssertNil(saved)
        XCTAssertEqual(model.settings, original)
        XCTAssertEqual(model.expandedMacroID, macro.id)
        XCTAssertEqual(model.focusedField, second.focus)
        XCTAssertEqual(model.tokenDraft(for: second).text, "{KC_NOPE}")
        XCTAssertFalse(model.tokenDraft(for: second).issues.isEmpty)
        XCTAssertTrue(model.isDirty)
        model.updateTokenText("{KC_CMD}+{KC_V}", for: second)
        model.save()
        let value = try XCTUnwrap(saved)
        XCTAssertEqual(value.macros[0].shortcut.key, .function(14))
        XCTAssertEqual(value.macros[0].steps.map(\.kind), [
            .keys(.init(keyCode: 7, modifiers: .command)), .keys(.init(keyCode: 9, modifiers: .command))])
    }

    func testEmptyKeyDraftBlocksInactiveSaveAndCanBeRepairedByRecording() throws {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        let keyID = try XCTUnwrap(model.addKeyStep(macroID: macro.id))
        let field = TokenField.step(macroID: macro.id, stepID: keyID)
        model.updateTokenText("", for: field)
        var saved: AppSettings?
        model.onSave = { saved = $0 }
        model.save()
        XCTAssertNil(saved)
        XCTAssertEqual(model.focusedField, field.focus)
        XCTAssertTrue(model.errors(for: macro.id).contains("키 조합 단계의 기준 키를 입력하세요"))
        model.mutateTokenDraft(field) { $0.applyRecorded(.init(key: .keyCode(53), modifiers: .shift)) }
        model.save()
        XCTAssertEqual(saved?.macros[0].steps.map(\.kind), [.keys(.init(keyCode: 53, modifiers: .shift))])
    }

    func testDelayValidationMessageFocusAndBoundaryRepair() throws {
        let macro = Fixtures.carbon(13)
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        let stepID = try XCTUnwrap(model.addDelayStep(macroID: macro.id))
        var saved: AppSettings?
        model.onSave = { saved = $0 }
        for milliseconds in [-1, 60_001] {
            model.updateDelay(milliseconds: milliseconds, macroID: macro.id, stepID: stepID)
            model.save()
            XCTAssertNil(saved)
            XCTAssertEqual(model.focusedField, .step(macroID: macro.id, stepID: stepID))
            XCTAssertTrue(model.errors(for: macro.id).contains("딜레이는 0~60,000ms의 정수여야 합니다"))
        }
        for milliseconds in [0, 60_000] {
            saved = nil
            model.updateDelay(milliseconds: milliseconds, macroID: macro.id, stepID: stepID)
            model.save()
            XCTAssertEqual(saved?.macros[0].steps.last?.kind, .delay(milliseconds: milliseconds))
        }
    }

    func testCombinedCharacterCountAndEmptySequenceMessages() {
        var macro = Fixtures.carbon(13)
        macro.steps = [.init(kind: .text("👨🏽‍💻")), .init(kind: .delay(milliseconds: 0)), .init(kind: .text("e\u{301}한"))]
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        XCTAssertEqual(model.characterCount(for: macro.id), 3)
        for step in macro.steps { model.deleteStep(macroID: macro.id, stepID: step.id) }
        XCTAssertEqual(model.characterCount(for: macro.id), 0)
        XCTAssertTrue(model.errors(for: macro.id).contains("활성 매크로의 실행 순서가 비어 있습니다"))
        model.addKeyStep(macroID: macro.id)
        XCTAssertFalse(model.errors(for: macro.id).contains("활성 매크로의 실행 순서가 비어 있습니다"))
    }

    func testMacroUndoRetainsStepDraftAndClearingHistoryRemovesIt() throws {
        let macro = MacroDefinition.newDraft()
        let model = SettingsViewModel(settings: .init(macros: [macro]), validator: .init())
        let keyID = try XCTUnwrap(model.addKeyStep(macroID: macro.id))
        let field = TokenField.step(macroID: macro.id, stepID: keyID)
        model.updateTokenText("{KC_NOPE}", for: field)
        model.delete(id: macro.id)
        XCTAssertTrue(model.prepareTokenEditsForSave())
        model.undoDelete()
        XCTAssertEqual(model.settings.macros[0].steps[0].id, keyID)
        XCTAssertEqual(model.tokenDraft(for: field).text, "{KC_NOPE}")
        XCTAssertFalse(model.prepareTokenEditsForSave())
        model.delete(id: macro.id)
        model.clearDeletionHistory()
        XCTAssertNil(model.tokenDrafts[field])
        XCTAssertNil(model.tokenDrafts[.shortcut(macro.id)])
        XCTAssertFalse(model.canUndoDelete)
    }
}
