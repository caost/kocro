import CoreGraphics
import XCTest
@testable import Kocro

final class EventBatchFactoryTests: XCTestCase {
    func testChunksPreserveExtendedGraphemeClustersAndAllText() {
        let factory = EventBatchFactory(api: EventAPISpy(), maximumUTF16Units: 4)
        let text = "A👨‍👩‍👧‍👦e\u{301}B"
        let chunks = factory.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(chunks, ["A", "👨‍👩‍👧‍👦", "e\u{301}B"])
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 4 || $0.count == 1 })
    }

    func testSingleGraphemeBeyondMaximumIsNotSplitOrDropped() {
        let factory = EventBatchFactory(api: EventAPISpy(), maximumUTF16Units: 2)
        let grapheme = "👨‍👩‍👧‍👦"
        XCTAssertEqual(factory.chunks(grapheme), [grapheme])
    }

    func testChunksRoundTripMultilineKoreanEnglishEmojiAndCombiningText() {
        let factory = EventBatchFactory(api: EventAPISpy(), maximumUTF16Units: 5)
        let text = "한글\nEnglish🙂e\u{301}"
        let chunks = factory.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 5 || $0.count == 1 })
    }

    func testBuildCreatesCompleteUnicodeAndTrailingBatchBeforePosting() throws {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 4)
        let batch = try factory.make(text: "abcdef", trailing: .enter)
        XCTAssertEqual(api.created, [.unicode("abcd"), .unicode("ef"), .keyDown(36, []), .keyUp(36, [])])
        XCTAssertEqual(api.posted, [])
        XCTAssertEqual(batch.count, 4)
    }

    func testCustomTrailingKeyUsesSameModifiersForOneDownUpPair() throws {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 20)
        _ = try factory.make(text: "a", trailing: .custom(keyCode: 36, modifiers: [.command, .shift]))
        XCTAssertEqual(Array(api.created.suffix(2)), [.keyDown(36, [.command, .shift]), .keyUp(36, [.command, .shift])])
    }

    func testEveryCreationFailurePreventsEntireBatchFromPosting() {
        for failureIndex in 1...4 {
            let api = EventAPISpy(failAt: failureIndex)
            let poster = EventBatchPoster(api: api, maximumUTF16Units: 4)
            let request = ExecutionRequest(id: UUID(), shortcut: "F13",
                steps: MacroStep.legacySteps(text: "abcdef", trailingKey: .tab), receivedAt: .now)
            XCTAssertThrowsError(try poster.buildAndPost(request), "failure index \(failureIndex)")
            XCTAssertEqual(api.posted, [], "failure index \(failureIndex)")
        }
    }

    func testValidBatchPostsInCreationOrder() throws {
        let api = EventAPISpy()
        let poster = EventBatchPoster(api: api, maximumUTF16Units: 4)
        let request = ExecutionRequest(id: UUID(), shortcut: "F13",
            steps: MacroStep.legacySteps(text: "abcdef", trailingKey: .space), receivedAt: .now)
        try poster.buildAndPost(request)
        XCTAssertEqual(api.posted, api.created)
    }

    func testInvalidTrailingDefinitionsFailBeforeCreatingAnyEvents() {
        let invalidValues: [TrailingKey] = [
            .custom(keyCode: nil, modifiers: []), .custom(keyCode: 55, modifiers: []),
            .customFunction(13), .customFunction(21),
        ]
        for trailing in invalidValues {
            let api = EventAPISpy()
            let factory = EventBatchFactory(api: api, maximumUTF16Units: 20)
            XCTAssertThrowsError(try factory.make(text: "secret", trailing: trailing))
            XCTAssertEqual(api.created, [])
            XCTAssertEqual(api.posted, [])
        }
    }

    func testSegmentsPreserveMixedOrderAndAccumulateOnlyInterSegmentDelays() throws {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 4)
        let segments = try factory.makeSegments(steps: sequence)
        XCTAssertEqual(segments.map(\.events), [
            [.keyDown(8, .command), .keyUp(8, .command)],
            [.unicode("abcd"), .unicode("ef")],
            [.keyDown(9, [.command, .shift]), .keyUp(9, [.command, .shift])],
        ])
        XCTAssertEqual(segments.map(\.delayAfterMilliseconds), [500, 25, 0])
        XCTAssertTrue(api.posted.isEmpty)
    }

    func testSleepOccursAfterCompleteSegmentsAndNeverAfterFinalSegment() throws {
        let api = EventAPISpy()
        var waits: [Int] = []
        var postedAtWait: [[Kocro.EventKind]] = []
        let poster = EventBatchPoster(api: api, maximumUTF16Units: 4, sleep: { milliseconds in
            waits.append(milliseconds)
            postedAtWait.append(api.posted)
            XCTAssertEqual(api.created.count, 6, "All events must exist before any wait")
        })
        try poster.buildAndPost(.init(id: UUID(), shortcut: "F13", steps: sequence, receivedAt: .now))
        XCTAssertEqual(waits, [500, 25])
        XCTAssertEqual(postedAtWait, [
            [.keyDown(8, .command), .keyUp(8, .command)],
            [.keyDown(8, .command), .keyUp(8, .command), .unicode("abcd"), .unicode("ef")],
        ])
        XCTAssertEqual(api.posted, api.created)
    }

    func testFailureInAnyMixedSequenceEventPreventsAllPostingAndWaiting() {
        for failureIndex in 1...6 {
            let api = EventAPISpy(failAt: failureIndex)
            var waits: [Int] = []
            let poster = EventBatchPoster(api: api, maximumUTF16Units: 4, sleep: { waits.append($0) })
            XCTAssertThrowsError(try poster.buildAndPost(.init(
                id: UUID(), shortcut: "F13", steps: sequence, receivedAt: .now)))
            XCTAssertTrue(api.posted.isEmpty, "failure index \(failureIndex)")
            XCTAssertTrue(waits.isEmpty, "failure index \(failureIndex)")
        }
    }

    func testInvalidSequenceIsRejectedBeforeEventCreation() {
        let invalidKinds: [MacroStep.Kind] = [
            .delay(milliseconds: -1), .delay(milliseconds: 60_001),
            .keys(.init(keyCode: 55, modifiers: [])),
            .keys(.init(keyCode: 8, modifiers: .init(rawValue: 0x10))),
        ]
        for kind in invalidKinds {
            let api = EventAPISpy()
            let factory = EventBatchFactory(api: api, maximumUTF16Units: 20)
            XCTAssertThrowsError(try factory.makeSegments(steps: [.init(kind: .text("first")), .init(kind: kind)]))
            XCTAssertTrue(api.created.isEmpty)
            XCTAssertTrue(api.posted.isEmpty)
        }
    }

    func testEmptyAndDelayOnlySequencesDoNotWaitOrPost() throws {
        for steps: [MacroStep] in [[], [.init(kind: .delay(milliseconds: 500)), .init(kind: .text(""))]] {
            let api = EventAPISpy()
            var waits: [Int] = []
            let poster = EventBatchPoster(api: api, maximumUTF16Units: 20, sleep: { waits.append($0) })
            try poster.buildAndPost(.init(id: UUID(), shortcut: "F13", steps: steps, receivedAt: .now))
            XCTAssertTrue(api.created.isEmpty)
            XCTAssertTrue(api.posted.isEmpty)
            XCTAssertTrue(waits.isEmpty)
        }
    }

    private var sequence: [MacroStep] {
        [
            .init(kind: .delay(milliseconds: 100)),
            .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
            .init(kind: .delay(milliseconds: 200)),
            .init(kind: .text("")),
            .init(kind: .delay(milliseconds: 300)),
            .init(kind: .text("abcdef")),
            .init(kind: .delay(milliseconds: 25)),
            .init(kind: .keys(.init(keyCode: 9, modifiers: [.command, .shift]))),
            .init(kind: .delay(milliseconds: 60_000)),
            .init(kind: .text("")),
        ]
    }

    func testProductionChunkLimitIsTwentyUTF16Units() {
        XCTAssertEqual(CoreGraphicsBatchPoster.maximumUTF16Units, 20)
    }

    func testSystemAPIStoresExactUnicodeAndTrailingModifierFlags() throws {
        let api = SystemEventAPI()
        let text = "한글\nEnglish🙂e\u{301}"
        let unicodeEvent = try XCTUnwrap(api.create(.unicode(text)))
        var actualLength = 0
        var units = [UniChar](repeating: 0, count: text.utf16.count)
        unicodeEvent.keyboardGetUnicodeString(maxStringLength: units.count,
            actualStringLength: &actualLength, unicodeString: &units)
        XCTAssertEqual(String(utf16CodeUnits: units, count: actualLength), text)
        // Trigger modifiers must not turn Unicode input into shortcuts.
        XCTAssertTrue(unicodeEvent.flags.isEmpty)
        let expectedFlags: CGEventFlags = [.maskCommand, .maskShift]
        let down = try XCTUnwrap(api.create(.keyDown(36, [.command, .shift])))
        let up = try XCTUnwrap(api.create(.keyUp(36, [.command, .shift])))
        XCTAssertEqual(down.flags.intersection(expectedFlags), expectedFlags)
        XCTAssertEqual(up.flags.intersection(expectedFlags), expectedFlags)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), 36)
    }
}
