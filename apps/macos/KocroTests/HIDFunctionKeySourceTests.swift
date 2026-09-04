import XCTest
@testable import Kocro

final class HIDFunctionKeySourceTests: XCTestCase {
    func testValidatedOldSessionDoesNotRouteAgainstReplacementGeneration() {
        let api = HIDAPISpy()
        let validated = expectation(description: "old session validated")
        let staleFinished = expectation(description: "stale callback finished")
        let release = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var shouldPause = true
        let source = HIDFunctionKeySource(
            api: api,
            beforeEmit: {
                hookLock.lock()
                let pause = shouldPause
                shouldPause = false
                hookLock.unlock()
                if pause {
                    validated.fulfill()
                    release.wait()
                }
            },
            permissionCheck: { true }
        )
        let coordinator = ShortcutCoordinator(carbon: CarbonSpy(), hid: source)
        let oldMacro = Fixtures.hid(21)
        let newMacro = Fixtures.hid(21)
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }

        _ = coordinator.replace(with: [oldMacro])
        DispatchQueue.global().async {
            api.send(session: 0, usage: 0x70, value: 1, instant: .now)
            staleFinished.fulfill()
        }
        wait(for: [validated], timeout: 1)

        _ = coordinator.replace(with: [newMacro])
        release.signal()
        wait(for: [staleFinished], timeout: 1)
        api.send(session: 1, usage: 0x70, value: 1, instant: .now)

        XCTAssertEqual(triggered, [newMacro.id])
    }

    func testOnlyRequestedUsageAndPressEdgesTrigger() {
        XCTAssertEqual(HIDFunctionKeySource.matchingUsages([21, 24]), [0x70, 0x73])
        let api = HIDAPISpy()
        let sink = TriggerSpy()
        let source = HIDFunctionKeySource(api: api)
        source.onFunction = { _, function, instant in sink.call(function, instant) }

        XCTAssertNotNil(source.start(functions: [21]))
        XCTAssertEqual(api.matchingUsages, [0x70])

        api.send(usage: 0x70, value: 1)
        api.send(usage: 0x70, value: 1)
        api.send(usage: 0x70, value: 0)
        api.send(usage: 0x71, value: 1)
        api.send(usage: 0x70, value: 1)
        source.stop()

        XCTAssertEqual(sink.functions, [21, 21])
    }

    func testStopAndRestartIgnoreStaleCallbacksDuringConcurrentDelivery() {
        let api = HIDAPISpy()
        let sink = TriggerSpy()
        let source = HIDFunctionKeySource(api: api)
        source.onFunction = { _, function, instant in sink.call(function, instant) }
        let staleInstant = ContinuousClock.now
        let currentInstant = ContinuousClock.now

        XCTAssertNotNil(source.start(functions: [21]))
        source.stop()
        XCTAssertNotNil(source.start(functions: [21]))

        api.send(session: 0, usage: 0x70, value: 1, instant: staleInstant)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            api.send(
                session: index == 0 ? 1 : 0,
                usage: 0x70,
                value: 1,
                instant: index == 0 ? currentInstant : staleInstant
            )
        }
        source.stop()

        XCTAssertEqual(sink.functions, [21])
        XCTAssertEqual(sink.instants, [currentInstant])
    }
}
