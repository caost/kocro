import AppKit
import XCTest
@testable import Kocro

@MainActor
final class KeyRecorderTests: XCTestCase {
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
        for mode: KeyInputMode in [.shortcut, .trailing] {
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
