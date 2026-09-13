import XCTest
@testable import Kocro

@MainActor
final class MacroPipelineIntegrationTests: XCTestCase {
    func testOneHundredRapidTriggersPreserveExactSnapshotsAndSerialPosting() async {
        let harness = PipelineHarness(accessibility: true)
        let macros = (0..<100).map { index in
            var macro = Fixtures.macro(text: "value-\(index)")
            macro.steps.append(contentsOf: [
                .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
                .init(kind: .delay(milliseconds: index)),
                .init(kind: .keys(.init(keyCode: 9, modifiers: .command))),
            ])
            return macro
        }

        harness.install(macros)
        macros.forEach { harness.trigger($0.id) }
        await harness.drain()

        XCTAssertEqual(harness.poster.requests.map(\.steps), macros.map(\.steps))
        XCTAssertEqual(harness.maximumConcurrentPosts, 1)
    }

    func testFailedSaveExecutesOldSnapshotThenSuccessfulSaveExecutesNewSnapshot() async {
        let harness = PipelineHarness(accessibility: true)
        let old = Fixtures.macro(text: "old")
        harness.install([old])
        let edited = old.withText("new")
        harness.app.draft.macros[0] = edited
        harness.failNextSave()
        harness.saveAndTrigger()
        await harness.drain()

        XCTAssertEqual(harness.poster.requests.map(\.steps), [old.steps])

        harness.saveAndTrigger()
        await harness.drain()

        XCTAssertEqual(harness.poster.requests.map(\.steps), [old.steps, edited.steps])
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
        XCTAssertEqual(harness.poster.requests.map(\.steps), [successful.steps])
        XCTAssertEqual(harness.app.registration[conflicted.id], .registrationFailed)
    }

    func testUnicodeAndKeyStepsAreCopiedWithoutTransformation() async {
        let harness = PipelineHarness(accessibility: true)
        var macro = Fixtures.macro(text: "첫째 줄\n👨‍👩‍👧‍👦 e\u{301}")
        macro.steps.append(.init(kind: .keys(.init(keyCode: 0, modifiers: [.command, .shift]))))

        harness.install([macro])
        harness.trigger(macro.id)
        await harness.drain()

        XCTAssertEqual(harness.poster.requests.map(\.steps), [macro.steps])
    }

    func testKeyOnlyMacroRunsAndDelayOnlyMacroDoesNotRun() async {
        let harness = PipelineHarness(accessibility: true)
        var keys = Fixtures.carbon(13)
        keys.steps = [
            .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
            .init(kind: .delay(milliseconds: 500)),
            .init(kind: .keys(.init(keyCode: 9, modifiers: .command))),
        ]
        var delayOnly = Fixtures.carbon(14)
        delayOnly.steps = [.init(kind: .delay(milliseconds: 500))]
        delayOnly.isEnabled = false
        harness.install([keys, delayOnly])

        harness.trigger(keys.id)
        harness.trigger(delayOnly.id)
        await harness.drain()

        XCTAssertEqual(harness.poster.requests.map(\.steps), [keys.steps])
    }
}
