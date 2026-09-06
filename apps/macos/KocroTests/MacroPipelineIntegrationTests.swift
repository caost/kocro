import XCTest
@testable import Kocro

@MainActor
final class MacroPipelineIntegrationTests: XCTestCase {
    func testOneHundredRapidTriggersPreserveExactSnapshotsAndSerialPosting() async {
        let harness = PipelineHarness(accessibility: true)
        let macros = (0..<100).map { index in
            Fixtures.macro(text: "value-\(index)")
        }

        harness.install(macros)
        macros.forEach { harness.trigger($0.id) }
        await harness.drain()

        XCTAssertEqual(harness.postedTexts, (0..<100).map { "value-\($0)" })
        XCTAssertEqual(harness.maximumConcurrentPosts, 1)
    }

    func testFailedSaveExecutesOldSnapshotThenSuccessfulSaveExecutesNewSnapshot() async {
        let harness = PipelineHarness(accessibility: true)
        harness.install([Fixtures.macro(text: "old")])

        harness.editText("new")
        harness.failNextSave()
        harness.saveAndTrigger()
        await harness.drain()

        XCTAssertEqual(harness.postedTexts, ["old"])

        harness.saveAndTrigger()
        await harness.drain()

        XCTAssertEqual(harness.postedTexts, ["old", "new"])
    }

    func testCollisionCandidatePersistsDisabledMacroAndRunsSuccessfulMacro() async {
        let harness = PipelineHarness(accessibility: true)
        harness.install([Fixtures.macro(text: "old")])
        let successful = Fixtures.carbon(13)
        let conflicted = Fixtures.carbon(14)
        let edited = AppSettings(macros: [successful, conflicted])
        var normalized = edited
        normalized.macros[1].isEnabled = false
        harness.shortcuts.states = [
            successful.id: .registered,
            conflicted.id: .registrationFailed,
        ]
        harness.shortcuts.nextCandidateSettings = normalized
        harness.app.draft = edited

        harness.app.save()
        harness.trigger(successful.id)
        harness.trigger(conflicted.id)
        await harness.drain()

        XCTAssertEqual(harness.store.savedValues.last, normalized)
        XCTAssertEqual(harness.postedTexts, [successful.text])
        XCTAssertEqual(harness.app.registration[conflicted.id], .registrationFailed)
    }

    func testUnicodeAndTrailingKeyAreCopiedWithoutTransformation() async {
        let harness = PipelineHarness(accessibility: true)
        var macro = Fixtures.macro(text: "첫째 줄\n👨‍👩‍👧‍👦 e\u{301}")
        macro.trailingKey = .custom(keyCode: 0, modifiers: [.command, .shift])

        harness.install([macro])
        harness.trigger(macro.id)
        await harness.drain()

        XCTAssertEqual(harness.postedTexts, [macro.text])
        XCTAssertEqual(harness.postedTrailingKeys, [macro.trailingKey])
    }
}
