import AppKit
import XCTest
@testable import Kocro

@MainActor
final class ViewModelTests: XCTestCase {
    func testExecutionTokenInputAndCompletionExcludeF21ThroughF24() {
        for number in 21...24 {
            XCTAssertThrowsError(
                try TokenShortcutCodec.parse("{KC_F\(number)}", mode: .shortcut)
            )
        }
        XCTAssertEqual(
            TokenShortcutCodec.completions(for: "{KC_F2", mode: .shortcut),
            ["{KC_F2}", "{KC_F20}"]
        )
    }

    func testSettingsStartsInMacrosSectionAndSupportsGeneralSelection() {
        let model = SettingsViewModel(settings: .init(macros: []), validator: .init())

        XCTAssertEqual(model.selectedSection, .macros)

        model.selectedSection = .general

        XCTAssertEqual(model.selectedSection, .general)
        XCTAssertEqual(SettingsSection.allCases, [.macros, .general])
    }

    func testGeneralSettingsExposesLoginAndAccessibility() {
        let permissions = GeneralPermissionSpy(
            state: .init(accessibility: false)
        )
        let app = AppController(
            store: StoreSpy(loadResult: .success(.init(macros: []))),
            shortcuts: ShortcutSpy(),
            permissions: permissions,
            queue: QueueSpy()
        )
        app.start()
        let login = LoginItemController(service: LoginServiceSpy(status: .notRegistered))
        let general = GeneralSettingsViewModel(app: app, login: login)

        XCTAssertFalse(general.loginEnabled)
        XCTAssertNil(general.loginErrorMessage)
        XCTAssertFalse(general.accessibilityGranted)

        general.requestAccessibility()
        general.openAccessibilitySettings()
        XCTAssertEqual(permissions.accessibilityRequestCount, 1)
        XCTAssertEqual(permissions.openedSettings, [.accessibility])
    }

    func testActiveRefreshReconcilesRuntimeShortcuts() {
        let runtime = AppSettings(macros: [Fixtures.carbon(13)])
        let permissions = PermissionSpy(state: .init(accessibility: true))
        let shortcuts = ShortcutSpy()
        let app = AppController(
            store: StoreSpy(loadResult: .success(runtime)),
            shortcuts: shortcuts,
            permissions: permissions,
            queue: QueueSpy()
        )
        app.start()
        permissions.refreshedState = .init(accessibility: true)

        app.refreshPermissions(reconcileShortcuts: true)

        XCTAssertEqual(shortcuts.commitCount, 2)
        XCTAssertEqual(shortcuts.prepareCalls.last, runtime)
    }

    func testInjectedAppMenuActionsInvokeEachClosureOnce() {
        var settingsOpenCount = 0
        var aboutCount = 0
        var terminateCount = 0
        let actions = AppMenuActions(
            openSettings: { settingsOpenCount += 1 },
            openAbout: { aboutCount += 1 },
            terminate: { terminateCount += 1 }
        )

        actions.openSettings()
        actions.openAbout()
        actions.terminate()

        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(aboutCount, 1)
        XCTAssertEqual(terminateCount, 1)
    }

    func testLegacySettingsWindowActionStopsAfterPreferencesSelectorSucceeds() {
        var selectors: [Selector] = []
        let action = LegacySettingsWindowAction { selector in
            selectors.append(selector)
            return true
        }

        action.open()

        XCTAssertEqual(selectors.map(NSStringFromSelector), ["showPreferencesWindow:"])
    }

    func testLegacySettingsWindowActionFallsBackToSettingsSelector() {
        var selectors: [Selector] = []
        let action = LegacySettingsWindowAction { selector in
            selectors.append(selector)
            return false
        }

        action.open()

        XCTAssertEqual(
            selectors.map(NSStringFromSelector),
            ["showPreferencesWindow:", "showSettingsWindow:"]
        )
    }

    func testStatusPriorityAndRegisteredCount() {
        let menu = MenuBarViewModel(
            statuses: [.accessibilityRequired, .settingsError],
            registrations: [.registered, .registrationFailed, .registered]
        )

        XCTAssertEqual(menu.statusText, "설정 오류")
        XCTAssertEqual(menu.registeredCount, 2)
        XCTAssertEqual(
            MenuBarViewModel(
                statuses: [.accessibilityRequired],
                registrations: []
            ).statusText,
            "Accessibility 권한 필요"
        )
    }

    func testRecentExecutionUsesUserTitleOrUUIDNeverMacroText() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "A1B2C3D4-1111-2222-3333-444444444444")
        )
        let result = ExecutionResult(
            id: id,
            shortcut: "F13",
            kind: .postingRequested,
            date: Date()
        )

        XCTAssertEqual(
            MenuBarViewModel.recentTitle(
                result: result,
                macros: [Fixtures.macro(id: id, title: "인사", text: "비밀")]
            ),
            "인사"
        )
        XCTAssertEqual(
            MenuBarViewModel.recentTitle(
                result: result,
                macros: [Fixtures.macro(id: id, title: "", text: "비밀")]
            ),
            "매크로 A1B2C3D4"
        )
    }

    func testNativeMenuDescriptorsHaveRequiredOrderAndOmitEmptyRecentRun() {
        XCTAssertEqual(
            MenuBarViewModel.menuItems(hasRecentResult: false),
            [.status, .settings, .about, .quit]
        )
        XCTAssertEqual(
            MenuBarViewModel.menuItems(hasRecentResult: true),
            [.status, .recentExecution, .settings, .about, .quit]
        )
    }

    func testRecentExecutionDetailUsesShortcutAndConcreteResult() {
        let id = UUID()
        let date = Date()

        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .postingRequested),
            "게시 요청 완료"
        )
        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .accessibilityRequired),
            "Accessibility 권한 필요"
        )
        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .eventCreationFailed),
            "이벤트 생성 실패"
        )
        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .missingDefinition),
            "매크로 정의 없음"
        )
        XCTAssertEqual(
            MenuBarViewModel.recentDetail(
                result: ExecutionResult(
                    id: id,
                    shortcut: "⌘ A",
                    kind: .postingRequested,
                    date: date
                ),
                relativeDateText: "1분 전"
            ),
            "⌘ A · 게시 요청 완료 · 1분 전"
        )
    }

    func testAboutPanelContentUsesBundleMetadataAndAccessibleGitHubLink() {
        let content = AboutPanelContent(info: [
            "CFBundleDisplayName": "Kocro",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "NSHumanReadableCopyright": "Copyright © 2026 caost",
        ])

        XCTAssertEqual(content.applicationName, "Kocro")
        XCTAssertEqual(content.version, "1.0 (1)")
        XCTAssertEqual(content.copyright, "Copyright © 2026 caost")
        XCTAssertEqual(content.repositoryURL.absoluteString, "https://github.com/caost/kocro")
        XCTAssertEqual(content.credits.string, "GitHub")
        XCTAssertEqual(
            content.options[.copyright] as? String,
            "Copyright © 2026 caost"
        )
        XCTAssertEqual(
            content.credits.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            content.repositoryURL
        )
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

    func testShortcutTokenParserNormalizesAliasWhitespaceAndOrder() throws {
        let parsed = try TokenShortcutCodec.parse(
            " {KC_F13} + {KC_LCMD} ", mode: .shortcut
        )
        XCTAssertEqual(
            parsed.value,
            .shortcut(ShortcutDefinition(key: .function(13), modifiers: .command))
        )
        XCTAssertEqual(parsed.canonicalText, "{KC_CMD}+{KC_F13}")
    }

    func testTokenParserPreservesInvalidInputAndReportsTokenRange() {
        let source = "{KC_CMD}+{KC_NOPE}"
        let result = TokenShortcutCodec.validate(source, mode: .shortcut)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.issues.first?.token, "{KC_NOPE}")
        let range = result.issues.first?.range
        XCTAssertEqual(range.map { String(source[$0]) }, "{KC_NOPE}")
    }

    func testTokenParserAppliesFieldSpecificRules() {
        XCTAssertEqual(
            try TokenShortcutCodec.parse("", mode: .shortcut).value,
            .shortcut(.init(key: .empty, modifiers: []))
        )
        XCTAssertThrowsError(try TokenShortcutCodec.parse("{KC_F21}", mode: .shortcut))
        XCTAssertThrowsError(
            try TokenShortcutCodec.parse("{KC_CMD}+{KC_F21}", mode: .shortcut)
        )
        XCTAssertNoThrow(try TokenShortcutCodec.parse("{KC_ESC}", mode: .trailing))
        XCTAssertNoThrow(try TokenShortcutCodec.parse("{KC_BSPC}", mode: .trailing))
        XCTAssertThrowsError(try TokenShortcutCodec.parse("{KC_F21}", mode: .trailing))
        XCTAssertEqual(
            try TokenShortcutCodec.parse("{KC_SHIFT}+{KC_F20}", mode: .trailing).value,
            .trailing(.custom(keyCode: 90, modifiers: .shift))
        )
        XCTAssertEqual(
            try TokenShortcutCodec.parse("{KC_ENTER}", mode: .trailing).value,
            .trailing(.enter)
        )
        XCTAssertEqual(
            try TokenShortcutCodec.parse("{KC_CMD}+{KC_ENTER}", mode: .trailing).value,
            .trailing(.custom(keyCode: 36, modifiers: .command))
        )
    }

    func testTokenCompletionsUseNaturalOrderAndModeSpecificFunctionRange() {
        let shortcutFunctions = TokenShortcutCodec.completions(
            for: "{KC_F",
            mode: .shortcut
        )
        let trailingFunctions = TokenShortcutCodec.completions(
            for: "{KC_F",
            mode: .trailing
        )

        XCTAssertEqual(shortcutFunctions, ["{KC_F}"] + (1...20).map { "{KC_F\($0)}" })
        XCTAssertEqual(trailingFunctions, ["{KC_F}"] + (1...20).map { "{KC_F\($0)}" })
    }

    func testTokenEditorModelKeepsInvalidTextAndNormalizesOnCommit() {
        var model = TokenEditorDraft(
            value: .shortcut(.init(key: .function(13), modifiers: .command)),
            mode: .shortcut
        )

        model.updateText("{KC_CMD}+{KC_NOPE}")

        XCTAssertFalse(model.commit())
        XCTAssertEqual(model.text, "{KC_CMD}+{KC_NOPE}")
        XCTAssertFalse(model.issues.isEmpty)

        model.updateText("{KC_F13}+{KC_LCMD}")

        XCTAssertTrue(model.commit())
        XCTAssertEqual(model.text, "{KC_CMD}+{KC_F13}")
    }

    func testAutocompleteLimitsCandidatesAndMovesSelection() {
        var shortcut = TokenEditorDraft(
            value: .shortcut(.init(key: .empty, modifiers: [])),
            mode: .shortcut
        )

        shortcut.updateText("{KC_F2")

        XCTAssertEqual(
            shortcut.completions,
            ["{KC_F2}", "{KC_F20}"]
        )
        shortcut.moveCompletion(.down)
        shortcut.acceptCompletion()
        XCTAssertEqual(shortcut.text, "{KC_F20}")
        XCTAssertEqual(
            TokenShortcutCodec.completions(for: "{KC_F2", mode: .trailing),
            ["{KC_F2}", "{KC_F20}"]
        )
    }

    func testRecordedAndTypedInputsProduceSameStoredValues() throws {
        let recorded = try XCTUnwrap(
            KeyRecorderTranslator.shortcut(keyCode: 105, modifiers: [.command])
        )
        let typed = try TokenShortcutCodec.parse(
            "{KC_CMD}+{KC_F13}",
            mode: .shortcut
        ).value

        XCTAssertEqual(.shortcut(recorded), typed)
        let typedTrailing = try TokenShortcutCodec.parse(
            "{KC_ESC}",
            mode: .trailing
        ).value
        var trailingDraft = TokenEditorDraft(value: .trailing(nil), mode: .trailing)
        trailingDraft.applyRecorded(
            .init(key: .keyCode(53), modifiers: [])
        )
        XCTAssertEqual(typedTrailing, .trailing(.custom(keyCode: 53, modifiers: [])))
        XCTAssertEqual(trailingDraft.value, typedTrailing)
    }

    func testF21ThroughF24AreNeitherSelectableNorRecorderEvents() {
        var model = TokenEditorDraft(
            value: .shortcut(.init(key: .empty, modifiers: [])),
            mode: .shortcut
        )

        model.selectToken("{KC_F24}")

        XCTAssertEqual(model.value, .shortcut(.init(key: .empty, modifiers: [])))
        XCTAssertFalse(model.issues.isEmpty)
        XCTAssertNil(KeyRecorderTranslator.shortcut(keyCode: 110, modifiers: []))
    }

    func testTrailingTokensRoundTripEveryStoredShape() throws {
        let values: [TrailingKey?] = [
            nil,
            .enter,
            .space,
            .tab,
            .custom(keyCode: 53, modifiers: []),
            .custom(keyCode: 90, modifiers: .shift),
        ]

        for value in values {
            let text = TokenShortcutCodec.format(.trailing(value))
            if value == nil {
                XCTAssertEqual(text, "")
                continue
            }
            XCTAssertEqual(
                try TokenShortcutCodec.parse(text, mode: .trailing).value,
                .trailing(value)
            )
        }
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
            registration: .registrationFailed).label, "충돌")
        XCTAssertEqual(MacroStatusBadge.resolve(isEnabled: false, isDirty: false,
            registration: nil).label, "비활성")
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

    func testTokenAccessibilityReportsValueCompletionAndError() {
        var draft = TokenEditorDraft(value: .shortcut(
            .init(key: .empty, modifiers: [])), mode: .shortcut)
        draft.updateText("{KC_F2")
        draft.moveCompletion(.down)
        var state = TokenEditorAccessibilityState(fieldLabel: "실행 단축키", draft: draft)
        XCTAssertEqual(state.value, "{KC_F2")
        XCTAssertTrue(state.help.contains("선택"))
        draft.updateText("{KC_NOPE}")
        XCTAssertFalse(draft.commit())
        state = .init(fieldLabel: "실행 단축키", draft: draft)
        XCTAssertTrue(state.help.contains("지원하는 {KC_...} 토큰"))
        XCTAssertEqual(state.announcement, state.help)
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

    func testTokenIssuePresentationIncludesOffendingTokenForVisualAndAccessibilityErrors() throws {
        var draft = TokenEditorDraft(
            value: .shortcut(.init(key: .empty, modifiers: [])),
            mode: .shortcut
        )
        draft.updateText("{KC_CMD}+{KC_NOPE}")
        XCTAssertFalse(draft.commit())
        let issue = try XCTUnwrap(draft.issues.first)
        let presentation = TokenIssuePresentation(issue: issue)

        XCTAssertTrue(presentation.message.contains("{KC_NOPE}"))
        XCTAssertEqual(presentation.accessibilityMessage, presentation.message)
        let accessibility = TokenEditorAccessibilityState(
            fieldLabel: "실행 단축키",
            draft: draft
        )
        XCTAssertTrue(accessibility.help.contains("{KC_NOPE}"))
        XCTAssertEqual(accessibility.announcement, accessibility.help)
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

    func testShortcutTokensUseReadableNamesAndFixedModifierOrder() {
        XCTAssertEqual(
            ShortcutDefinition(
                key: .function(13),
                modifiers: [.control, .option, .shift, .command]
            ).tokens,
            ["⌃ Control", "⌥ Option", "⇧ Shift", "⌘ Command", "F13"]
        )

        let readableKeyNames: [(UInt16, String)] = [
            (0, "A"), (18, "1"), (27, "-"), (36, "Return"),
            (123, "Left Arrow"), (82, "Keypad 0"),
        ]
        for (keyCode, expectedName) in readableKeyNames {
            XCTAssertEqual(
                ShortcutDefinition(key: .keyCode(keyCode), modifiers: []).tokens,
                [expectedName]
            )
        }
    }

    func testShortcutRecorderDecisionsClearOrResignDespiteModifiers() {
        let allModifiers: ModifierSet = [.control, .option, .shift, .command]

        for keyCode: UInt16 in [51, 117] {
            XCTAssertEqual(
                KeyRecorderTranslator.decision(
                    keyCode: keyCode,
                    modifiers: allModifiers,
                    isRepeat: false,
                    mode: .shortcut
                ),
                .clear
            )
        }
        XCTAssertEqual(
            KeyRecorderTranslator.decision(
                keyCode: 53,
                modifiers: allModifiers,
                isRepeat: false,
                mode: .shortcut
            ),
            .resignFocus
        )
    }

    func testTrailingRecorderRecordsDeleteBackspaceAndEscape() {
        for keyCode: UInt16 in [51, 53, 117] {
            XCTAssertEqual(
                KeyRecorderTranslator.decision(
                    keyCode: keyCode,
                    modifiers: [],
                    isRepeat: false,
                    mode: .trailing
                ),
                .record(.init(key: .keyCode(keyCode), modifiers: []))
            )
        }
    }

    func testRecorderKeepsCurrentValueAndFocusForIgnoredInput() {
        for mode: KeyRecorderMode in [.shortcut, .trailing] {
            XCTAssertEqual(
                KeyRecorderTranslator.decision(
                    keyCode: 0,
                    modifiers: .command,
                    isRepeat: true,
                    mode: mode
                ),
                .keepValue
            )
            XCTAssertEqual(
                KeyRecorderTranslator.decision(
                    keyCode: 55,
                    modifiers: [],
                    isRepeat: false,
                    mode: mode
                ),
                .keepValue
            )
            XCTAssertEqual(
                KeyRecorderTranslator.decision(
                    keyCode: 110,
                    modifiers: [],
                    isRepeat: false,
                    mode: mode
                ),
                .keepValue
            )
        }
    }

    func testRecorderValidInputReturnsCompleteReplacement() {
        XCTAssertEqual(
            KeyRecorderTranslator.decision(
                keyCode: 0,
                modifiers: [.control, .command],
                isRepeat: false,
                mode: .shortcut
            ),
            .record(.init(key: .keyCode(0), modifiers: [.control, .command]))
        )
        XCTAssertEqual(
            KeyRecorderTranslator.decision(
                keyCode: 90,
                modifiers: .shift,
                isRepeat: false,
                mode: .trailing
            ),
            .record(.init(key: .function(20), modifiers: .shift))
        )
    }

    func testTrailingFunctionStoredModelBindingKeepsReadableAccessibleTokensAfterUpdate() throws {
        let cases: [(number: Int, keyCode: UInt16)] = [(1, 122), (20, 90)]

        for testCase in cases {
            let storedValue = TrailingKey.custom(
                keyCode: testCase.keyCode,
                modifiers: .shift
            )
            let bindingValue = ShortcutDefinition(trailingKey: storedValue)
            let expectedTokens = ["⇧ Shift", "F\(testCase.number)"]

            XCTAssertEqual(
                bindingValue,
                ShortcutDefinition(
                    key: .function(testCase.number),
                    modifiers: .shift
                )
            )
            XCTAssertEqual(bindingValue.tokens, expectedTokens)

            let recorder = RecorderView(initialTokens: [])
            recorder.tokens = bindingValue.tokens

            XCTAssertEqual(recorder.tokens, expectedTokens)
            XCTAssertEqual(
                recorder.accessibilityValue() as? String,
                expectedTokens.joined(separator: ", ")
            )
        }
    }

    func testRecorderExposesAccessibleControlStateAndUpdatesItsValue() {
        let view = RecorderView()

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityValue() as? String, "설정 안 됨")
        XCTAssertNotNil(view.accessibilityHelp())

        view.tokens = ["⌃ Control", "⌘ Command", "A"]

        XCTAssertEqual(
            view.accessibilityValue() as? String,
            "⌃ Control, ⌘ Command, A"
        )
    }

    func testRecorderKeepsKeyRecordingPromptVisibleAfterValueChanges() {
        let view = RecorderView(initialTokens: [])
        view.prompt = "키로 기록"
        let emptyWidth = view.intrinsicContentSize.width

        view.tokens = ["⌥ Option", "⌘ Command", "I"]

        XCTAssertEqual(view.visibleLabel, "키로 기록")
        XCTAssertEqual(view.intrinsicContentSize.width, emptyWidth)
        XCTAssertEqual(view.accessibilityValue() as? String, "⌥ Option, ⌘ Command, I")
    }

    func testMacroActivationUsesSwitchControl() {
        XCTAssertEqual(MacroActivationToggle.controlKind, .switchToggle)
    }

    func testMacroRowsUseDistinctContextualRecorderLabelsWithoutChangingPrompts() throws {
        let macros = [
            MacroDefinition(
                id: try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
                title: "",
                isEnabled: false,
                shortcut: .init(key: .empty, modifiers: []),
                text: "",
                trailingKey: .custom(keyCode: nil, modifiers: [])
            ),
            MacroDefinition(
                id: try XCTUnwrap(UUID(uuidString: "11111111-2222-2222-2222-222222222222")),
                title: "",
                isEnabled: false,
                shortcut: .init(key: .empty, modifiers: []),
                text: "",
                trailingKey: .custom(keyCode: nil, modifiers: [])
            ),
        ]
        let rowLabels = macros.map(MacroRecorderAccessibilityLabels.init)

        XCTAssertNotEqual(rowLabels[0].shortcut, rowLabels[1].shortcut)
        XCTAssertNotEqual(rowLabels[0].trailing, rowLabels[1].trailing)
        XCTAssertTrue(rowLabels[0].shortcut.contains("이름 없는 매크로"))
        XCTAssertTrue(rowLabels[0].shortcut.contains(macros[0].id.uuidString))
        XCTAssertTrue(rowLabels[1].trailing.contains("이름 없는 매크로"))
        XCTAssertTrue(rowLabels[1].trailing.contains(macros[1].id.uuidString))

        let shortcutRecorder = RecorderView()
        shortcutRecorder.prompt = "단축키 입력"
        shortcutRecorder.recorderAccessibilityLabel = rowLabels[0].shortcut
        let trailingRecorder = RecorderView()
        trailingRecorder.prompt = "후속 키 입력"
        trailingRecorder.recorderAccessibilityLabel = rowLabels[0].trailing

        XCTAssertEqual(shortcutRecorder.prompt, "단축키 입력")
        XCTAssertEqual(trailingRecorder.prompt, "후속 키 입력")
        XCTAssertEqual(shortcutRecorder.accessibilityLabel(), rowLabels[0].shortcut)
        XCTAssertEqual(trailingRecorder.accessibilityLabel(), rowLabels[0].trailing)
    }

    func testRecorderAccessibilityPressMovesKeyboardFocusToControl() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = RecorderView(frame: NSRect(x: 10, y: 10, width: 300, height: 26))
        window.contentView?.addSubview(view)

        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(window.firstResponder === view)
    }

    func testFocusedRecorderOwnsCommandKeyEquivalentThroughRepeatAndRelease() throws {
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let saveActions = MenuActionSpy()
        let mainMenu = NSMenu(title: "Main")
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let saveItem = NSMenuItem(
            title: "Save",
            action: #selector(MenuActionSpy.save(_:)),
            keyEquivalent: "s"
        )
        saveItem.keyEquivalentModifierMask = .command
        saveItem.target = saveActions
        fileMenu.addItem(saveItem)
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(MenuActionSpy.quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = saveActions
        fileMenu.addItem(quitItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        NSApp.mainMenu = mainMenu

        let (window, _, recorder, after) = makeRecorderKeyViewLoop()
        var recorded: [ShortcutDefinition] = []
        recorder.onShortcut = { recorded.append($0) }
        XCTAssertTrue(window.makeFirstResponder(recorder))

        let keyDown = try keyEvent(
            keyCode: 1,
            modifiers: .command,
            characters: "s",
            in: window
        )
        let repeatedKeyDown = try keyEvent(
            keyCode: 1,
            modifiers: .command,
            characters: "s",
            isRepeat: true,
            in: window
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            keyCode: 1,
            modifiers: [],
            characters: "s",
            in: window
        )
        let unrelatedKeyUp = try keyEvent(
            type: .keyUp,
            keyCode: 0,
            modifiers: [],
            characters: "a",
            in: window
        )
        let otherKeyEquivalent = try keyEvent(
            keyCode: 12,
            modifiers: .command,
            characters: "q",
            in: window
        )
        XCTAssertTrue(window.performKeyEquivalent(with: keyDown))
        XCTAssertTrue(window.firstResponder === recorder)
        XCTAssertTrue(window.performKeyEquivalent(with: otherKeyEquivalent))
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(saveActions.quitCount, 0)

        window.sendEvent(unrelatedKeyUp)

        XCTAssertTrue(window.firstResponder === recorder)
        XCTAssertTrue(window.performKeyEquivalent(with: repeatedKeyDown))

        XCTAssertEqual(
            recorded,
            [.init(key: .keyCode(1), modifiers: .command)]
        )
        XCTAssertEqual(saveActions.saveCount, 0)

        window.sendEvent(keyUp)

        XCTAssertTrue(window.firstResponder === after)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(saveActions.saveCount, 0)
        XCTAssertEqual(saveActions.quitCount, 0)

        XCTAssertTrue(mainMenu.performKeyEquivalent(with: keyDown))
        XCTAssertEqual(saveActions.saveCount, 1)
        XCTAssertTrue(mainMenu.performKeyEquivalent(with: otherKeyEquivalent))
        XCTAssertEqual(saveActions.quitCount, 1)
    }

    func testRecorderClearsPendingKeyEquivalentWhenFocusMovesAway() throws {
        let (window, _, recorder, after) = makeRecorderKeyViewLoop()
        var recorded: [ShortcutDefinition] = []
        recorder.onShortcut = { recorded.append($0) }
        let commandS = try keyEvent(
            keyCode: 1,
            modifiers: .command,
            characters: "s",
            in: window
        )

        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(recorder.performKeyEquivalent(with: commandS))
        XCTAssertEqual(recorded.count, 1)

        XCTAssertTrue(window.makeFirstResponder(after))
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(recorder.performKeyEquivalent(with: commandS))

        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(window.firstResponder === recorder)
    }

    func testFocusedRecorderHandlesNonCommandKeyEquivalentThroughRelease() throws {
        let (window, _, recorder, after) = makeRecorderKeyViewLoop()
        var recorded: [ShortcutDefinition] = []
        recorder.onShortcut = { recorded.append($0) }
        XCTAssertTrue(window.makeFirstResponder(recorder))
        let keyDown = try keyEvent(
            keyCode: 0,
            modifiers: .option,
            characters: "a",
            in: window
        )
        let keyUp = try keyEvent(
            type: .keyUp,
            keyCode: 0,
            modifiers: .option,
            characters: "a",
            in: window
        )

        XCTAssertTrue(recorder.performKeyEquivalent(with: keyDown))
        XCTAssertEqual(
            recorded,
            [.init(key: .keyCode(0), modifiers: .option)]
        )
        XCTAssertTrue(window.firstResponder === recorder)

        recorder.keyUp(with: keyUp)

        XCTAssertTrue(window.firstResponder === after)
    }

    func testRecorderEntersFromKeyViewLoopAndUnmodifiedTabMovesToNextControl() throws {
        let (window, before, recorder, after) = makeRecorderKeyViewLoop()
        XCTAssertTrue(window.makeFirstResponder(before))

        window.selectNextKeyView(before)
        XCTAssertTrue(window.firstResponder === recorder)

        recorder.keyDown(with: try keyEvent(keyCode: 48, characters: "\t", in: window))
        XCTAssertTrue(window.firstResponder === after)
    }

    func testValidShortcutsIncludingShiftTabRecordThenReleaseFocus() throws {
        let (window, _, recorder, after) = makeRecorderKeyViewLoop()
        var recorded: [ShortcutDefinition] = []
        recorder.onShortcut = { recorded.append($0) }
        let events: [(UInt16, NSEvent.ModifierFlags, String, ShortcutDefinition)] = [
            (0, .command, "a", .init(key: .keyCode(0), modifiers: .command)),
            (48, .shift, "\t", .init(key: .keyCode(48), modifiers: .shift)),
        ]

        for (keyCode, modifiers, characters, expected) in events {
            XCTAssertTrue(window.makeFirstResponder(recorder))
            recorder.keyDown(with: try keyEvent(
                keyCode: keyCode,
                modifiers: modifiers,
                characters: characters,
                in: window
            ))
            XCTAssertEqual(recorded.last, expected)
            XCTAssertTrue(window.firstResponder === after)
        }
    }

    func testTrailingTabShiftTabAndEscapeRecordThenReleaseFocus() throws {
        let (window, _, recorder, after) = makeRecorderKeyViewLoop()
        recorder.mode = .trailing
        var recorded: [ShortcutDefinition] = []
        recorder.onShortcut = { recorded.append($0) }
        let events: [(UInt16, NSEvent.ModifierFlags, String, ShortcutDefinition)] = [
            (48, [], "\t", .init(key: .keyCode(48), modifiers: [])),
            (48, .shift, "\t", .init(key: .keyCode(48), modifiers: .shift)),
            (53, [], "\u{1b}", .init(key: .keyCode(53), modifiers: [])),
        ]

        for (keyCode, modifiers, characters, expected) in events {
            XCTAssertTrue(window.makeFirstResponder(recorder))
            recorder.keyDown(with: try keyEvent(
                keyCode: keyCode,
                modifiers: modifiers,
                characters: characters,
                in: window
            ))
            XCTAssertEqual(recorded.last, expected)
            XCTAssertTrue(window.firstResponder === after)
        }
    }

    func testRecorderPostsValueChangedOnlyWhenTokensActuallyChange() {
        let notifications = AccessibilityNotificationSpy()
        let view = RecorderView(
            frame: .zero,
            initialTokens: ["F21"],
            accessibilityNotifications: notifications
        )

        XCTAssertEqual(notifications.valueChangedElements.count, 0)
        XCTAssertEqual(view.accessibilityValue() as? String, "F21")

        view.tokens = ["⌘ Command", "A"]
        XCTAssertEqual(notifications.valueChangedElements.count, 1)
        XCTAssertTrue(notifications.valueChangedElements.last === view)

        view.tokens = ["⌘ Command", "A"]
        XCTAssertEqual(notifications.valueChangedElements.count, 1)

        view.tokens = ["F21"]
        XCTAssertEqual(notifications.valueChangedElements.count, 2)
    }

    func testRecorderIntrinsicWidthDoesNotChangeWithRecordedValue() {
        let view = RecorderView()
        let prompt = view.visibleLabel
        let promptWidth = view.intrinsicContentSize.width

        view.tokens = ShortcutDefinition(
            key: .keyCode(76),
            modifiers: [.control, .option, .shift, .command]
        ).tokens

        XCTAssertEqual(view.intrinsicContentSize.width, promptWidth)
        XCTAssertEqual(view.visibleLabel, prompt)
    }

    func testRecorderFocusDisplayStateTracksFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = RecorderView(frame: NSRect(x: 10, y: 10, width: 300, height: 26))
        window.contentView?.addSubview(view)

        view.needsDisplay = false
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(view.showsFocusRing)
        XCTAssertTrue(view.needsDisplay)

        view.needsDisplay = false
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(view.showsFocusRing)
        XCTAssertTrue(view.needsDisplay)
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

    private func makeRecorderKeyViewLoop() -> (NSWindow, NSButton, RecorderView, NSButton) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let before = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 26))
        let recorder = RecorderView(frame: NSRect(x: 100, y: 10, width: 400, height: 26))
        let after = NSButton(frame: NSRect(x: 510, y: 10, width: 80, height: 26))
        window.contentView?.addSubview(before)
        window.contentView?.addSubview(recorder)
        window.contentView?.addSubview(after)
        before.nextKeyView = recorder
        recorder.nextKeyView = after
        after.nextKeyView = before
        return (window, before, recorder, after)
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String,
        isRepeat: Bool = false,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
        ))
    }
}

private final class GeneralPermissionSpy: PermissionServing {
    var state: PermissionState
    private(set) var accessibilityRequestCount = 0
    private(set) var openedSettings: [PrivacyKind] = []

    init(state: PermissionState) {
        self.state = state
    }

    func refresh() -> PermissionState { state }
    func requestAccessibility() { accessibilityRequestCount += 1 }
    func openSettings(_ kind: PrivacyKind) { openedSettings.append(kind) }
    func currentAccessibility() -> Bool { state.accessibility }
}

private final class AccessibilityNotificationSpy: AccessibilityNotificationPosting {
    private(set) var valueChangedElements: [NSView] = []

    func postValueChanged(for element: NSView) {
        valueChangedElements.append(element)
    }
}

private final class MenuActionSpy: NSObject {
    private(set) var saveCount = 0
    private(set) var quitCount = 0

    @objc func save(_ sender: Any?) {
        saveCount += 1
    }

    @objc func quit(_ sender: Any?) {
        quitCount += 1
    }
}
