import CoreGraphics
import XCTest
@testable import Kocro

final class EventBatchFactoryTests: XCTestCase {
    func testChunksPreserveExtendedGraphemeClustersAndAllText() {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 4)
        let text = "A👨‍👩‍👧‍👦e\u{301}B"

        let chunks = factory.chunks(text)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(chunks, ["A", "👨‍👩‍👧‍👦", "e\u{301}B"])
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 4 || $0.count == 1 })
    }

    func testSingleGraphemeBeyondMaximumIsNotSplitOrDropped() {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 2)
        let grapheme = "👨‍👩‍👧‍👦"

        XCTAssertEqual(factory.chunks(grapheme), [grapheme])
    }

    func testChunksRoundTripMultilineKoreanEnglishEmojiAndCombiningText() {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 5)
        let text = "한글\nEnglish🙂e\u{301}"

        let chunks = factory.chunks(text)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 5 || $0.count == 1 })
    }

    func testBuildCreatesCompleteUnicodeAndTrailingBatchBeforePosting() throws {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 4)

        let batch = try factory.make(text: "abcdef", trailing: .enter)

        XCTAssertEqual(
            api.created,
            [.unicode("abcd"), .unicode("ef"), .keyDown(36, []), .keyUp(36, [])]
        )
        XCTAssertEqual(api.posted, [])
        XCTAssertEqual(batch.count, 4)
    }

    func testCustomTrailingKeyUsesSameModifiersForOneDownUpPair() throws {
        let api = EventAPISpy()
        let factory = EventBatchFactory(api: api, maximumUTF16Units: 20)

        _ = try factory.make(
            text: "a",
            trailing: .custom(keyCode: 36, modifiers: [.command, .shift])
        )

        XCTAssertEqual(
            Array(api.created.suffix(2)),
            [.keyDown(36, [.command, .shift]), .keyUp(36, [.command, .shift])]
        )
    }

    func testEveryCreationFailurePreventsEntireBatchFromPosting() {
        let expectedCreationCount = 4

        for failureIndex in 1...expectedCreationCount {
            let api = EventAPISpy(failAt: failureIndex)
            let poster = EventBatchPoster(api: api, maximumUTF16Units: 4)
            let request = ExecutionRequest(
                id: UUID(),
                shortcut: "F13",
                text: "abcdef",
                trailing: .tab,
                receivedAt: .now
            )

            XCTAssertThrowsError(try poster.buildAndPost(request), "failure index \(failureIndex)")
            XCTAssertEqual(api.posted, [], "failure index \(failureIndex)")
        }
    }

    func testValidBatchPostsInCreationOrder() throws {
        let api = EventAPISpy()
        let poster = EventBatchPoster(api: api, maximumUTF16Units: 4)
        let request = ExecutionRequest(
            id: UUID(),
            shortcut: "F13",
            text: "abcdef",
            trailing: .space,
            receivedAt: .now
        )

        try poster.buildAndPost(request)

        XCTAssertEqual(api.posted, api.created)
    }

    func testInvalidTrailingDefinitionsFailBeforeCreatingAnyEvents() {
        let invalidValues: [TrailingKey] = [
            .custom(keyCode: nil, modifiers: []),
            .custom(keyCode: 55, modifiers: []),
            .customFunction(13),
            .customFunction(21),
        ]

        for trailing in invalidValues {
            let api = EventAPISpy()
            let factory = EventBatchFactory(api: api, maximumUTF16Units: 20)

            XCTAssertThrowsError(try factory.make(text: "secret", trailing: trailing))
            XCTAssertEqual(api.created, [])
            XCTAssertEqual(api.posted, [])
        }
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
        unicodeEvent.keyboardGetUnicodeString(
            maxStringLength: units.count,
            actualStringLength: &actualLength,
            unicodeString: &units
        )

        XCTAssertEqual(String(utf16CodeUnits: units, count: actualLength), text)
        // 유니코드 이벤트는 flags 를 비워야 한다. 비우지 않으면 트리거 단축키의 보조 키(⌃⌥⌘ 등)가
        // .cghidEventTap 주입 시 병합되어 대상 앱이 문자를 단축키로 해석하고 삽입하지 않는다.
        XCTAssertTrue(
            unicodeEvent.flags.isEmpty,
            "유니코드 이벤트 flags 가 비어 있지 않다: \(unicodeEvent.flags.rawValue)"
        )

        let expectedFlags: CGEventFlags = [.maskCommand, .maskShift]
        let down = try XCTUnwrap(api.create(.keyDown(36, [.command, .shift])))
        let up = try XCTUnwrap(api.create(.keyUp(36, [.command, .shift])))
        XCTAssertEqual(down.flags.intersection(expectedFlags), expectedFlags)
        XCTAssertEqual(up.flags.intersection(expectedFlags), expectedFlags)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), 36)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), 36)
    }
}
