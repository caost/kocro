import AppKit
import XCTest
@testable import Kocro

@MainActor
final class TokenEditorTests: XCTestCase {
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

    func testKeyInputModelKeepsInvalidTextAndNormalizesOnCommit() {
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
}
