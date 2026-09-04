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
