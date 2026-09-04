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
            if shouldEnqueue {
                queue.enqueue(second)
            }
        }

        queue.enqueue(first)
        await queue.drain()

        XCTAssertEqual(poster.texts, ["first", "second"])
    }

    func testResultCallbackEnqueueDoesNotEmitStaleIdleTransition() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        let first = request(text: "first")
        let second = request(text: "second")
        let bothResults = expectation(description: "both results")
        bothResults.expectedFulfillmentCount = 2
        let transitions = BooleanRecorder()

        queue.onIdleChange = { isIdle in
            transitions.append(isIdle)
        }
        queue.onResult = { result in
            if result.id == first.id {
                queue.enqueue(second)
            }
            bothResults.fulfill()
        }

        queue.enqueue(first)
        await fulfillment(of: [bothResults], timeout: 2)
        await queue.drain()

        let observedTransitions = transitions.values
        XCTAssertEqual(observedTransitions, [false, true])
        XCTAssertEqual(observedTransitions.last, true)
        XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(poster.texts, ["first", "second"])
    }

    func testFIFOAndMaximumConcurrencyOneWhileFirstRequestIsBlocked() async {
        let poster = BlockingPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        let first = ExecutionRequest(
            id: UUID(),
            shortcut: "F13",
            text: "first",
            trailing: .space,
            receivedAt: .now
        )
        let second = ExecutionRequest(
            id: UUID(),
            shortcut: "F14",
            text: "second",
            trailing: nil,
            receivedAt: .now
        )

        queue.enqueue(first)
        XCTAssertTrue(poster.waitUntilFirstRequestEnters())
        queue.enqueue(second)
        XCTAssertEqual(poster.texts, ["first"])
        poster.releaseFirstRequest()
        await queue.drain()

        XCTAssertEqual(poster.texts, ["first", "second"])
        XCTAssertEqual(poster.maximumConcurrent, 1)
    }

    func testRequestKeepsTriggerTimeValueSnapshot() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { true })
        var sourceText = "before"
        var sourceTrailing: TrailingKey? = .enter
        let request = ExecutionRequest(
            id: UUID(),
            shortcut: "F13",
            text: sourceText,
            trailing: sourceTrailing,
            receivedAt: .now
        )

        sourceText = "after"
        sourceTrailing = .tab
        queue.enqueue(request)
        await queue.drain()

        XCTAssertEqual(poster.requests.map(\.text), ["before"])
        XCTAssertEqual(poster.requests.map(\.trailing), [.enter])
    }

    func testNoAccessibilityPostsNothingAndResultContainsNoMacroText() async {
        let poster = RecordingBatchPoster()
        let queue = MacroExecutionQueue(poster: poster, accessibility: { false })
        let request = ExecutionRequest(
            id: UUID(),
            shortcut: "⌘F13",
            text: "secret macro text",
            trailing: nil,
            receivedAt: .now
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
        let request = ExecutionRequest(
            id: UUID(),
            shortcut: "F13",
            text: "private value",
            trailing: nil,
            receivedAt: .now
        )

        queue.enqueue(request)
        await queue.drain()

        XCTAssertEqual(queue.lastResult?.kind, .eventCreationFailed)
        XCTAssertFalse(queue.lastResult?.description.contains("private value") ?? true)
    }

    private func request(text: String) -> ExecutionRequest {
        ExecutionRequest(
            id: UUID(),
            shortcut: "F13",
            text: text,
            trailing: nil,
            receivedAt: .now
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
