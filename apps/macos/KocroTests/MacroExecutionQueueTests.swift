import XCTest
@testable import Kocro

final class MacroExecutionQueueTests: XCTestCase {
    func testReentrantEnqueueFromBusyCallbackKeepsOriginalRequestFirst() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        let first = request(text: "first")
        let second = request(text: "second")
        let callbackLock = NSLock()
        var didEnqueueSecond = false

        queue.onIdleChange = { isIdle in
            guard !isIdle else { return }
            callbackLock.lock()
            let shouldEnqueue = !didEnqueueSecond
            didEnqueueSecond = true
            callbackLock.unlock()
            if shouldEnqueue { queue.enqueue(second) }
        }

        queue.enqueue(first)
        await queue.drain()

        XCTAssertEqual(poster.requests.map(\.steps), [first.steps, second.steps])
    }

    func testResultCallbackEnqueueDoesNotEmitStaleIdleTransition() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        let first = request(text: "first")
        let second = request(text: "second")
        let bothResults = expectation(description: "both results")
        bothResults.expectedFulfillmentCount = 2
        let transitions = BooleanRecorder()

        queue.onIdleChange = { transitions.append($0) }
        queue.onResult = { result in
            if result.id == first.id { queue.enqueue(second) }
            bothResults.fulfill()
        }

        queue.enqueue(first)
        await fulfillment(of: [bothResults], timeout: 2)
        await queue.drain()

        XCTAssertEqual(transitions.values, [false, true])
        XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(poster.requests.map(\.steps), [first.steps, second.steps])
    }

    func testFIFOAndMaximumConcurrencyOneWhileFirstRequestIsBlocked() async {
        let poster = BlockingPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        let first = ExecutionRequest(
            id: UUID(), shortcut: "F13",
            steps: [.init(kind: .text("first")),
                    .init(kind: .keys(.init(keyCode: 49, modifiers: [])))],
            receivedAt: .now
        )
        let second = request(text: "second")

        queue.enqueue(first)
        XCTAssertTrue(poster.waitUntilFirstRequestEnters())
        queue.enqueue(second)
        XCTAssertEqual(poster.texts, ["first"])
        poster.releaseFirstRequest()
        await queue.drain()

        XCTAssertEqual(poster.texts, ["first", "second"])
        XCTAssertEqual(poster.maximumConcurrent, 1)
    }

    func testRequestKeepsTriggerTimeSequenceSnapshot() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        var source: [MacroStep] = [
            .init(kind: .text("before")),
            .init(kind: .keys(.init(keyCode: 8, modifiers: .command))),
            .init(kind: .delay(milliseconds: 500)),
            .init(kind: .keys(.init(keyCode: 9, modifiers: .command))),
        ]
        let expected = source
        let snapshot = ExecutionRequest(
            id: UUID(), shortcut: "F13", steps: source, receivedAt: .now
        )

        source[0].kind = .text("after")
        source[2].kind = .delay(milliseconds: 100)
        source.reverse()
        queue.enqueue(snapshot)
        await queue.drain()

        XCTAssertNotEqual(source, expected)
        XCTAssertEqual(poster.requests.map(\.steps), [expected])
    }

    func testNoAccessibilityPostsNothingAndResultContainsNoMacroText() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { false })
        let request = ExecutionRequest(
            id: UUID(), shortcut: "⌘F13",
            steps: [.init(kind: .text("secret macro text"))], receivedAt: .now
        )

        queue.enqueue(request)
        await queue.drain()

        XCTAssertTrue(poster.requests.isEmpty)
        XCTAssertEqual(queue.lastResult?.kind, .accessibilityRequired)
        XCTAssertFalse(queue.lastResult?.description.contains("secret macro text") ?? true)
    }

    func testBuildFailureIsReportedWithoutLeakingMacroText() async {
        let poster = RecordingBatchPoster(error: EventBuildError.creationFailed)
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        let request = request(text: "private value")

        queue.enqueue(request)
        await queue.drain()

        XCTAssertEqual(queue.lastResult?.kind, .eventCreationFailed)
        XCTAssertFalse(queue.lastResult?.description.contains("private value") ?? true)
    }

    private func request(text: String) -> ExecutionRequest {
        ExecutionRequest(
            id: UUID(), shortcut: "F13",
            steps: [.init(kind: .text(text))], receivedAt: .now
        )
    }
}

private final class BooleanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
