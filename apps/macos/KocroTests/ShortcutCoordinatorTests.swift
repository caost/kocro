import XCTest
@testable import Kocro

final class ShortcutCoordinatorTests: XCTestCase {
    func testCarbonLifecycleRunsOnMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        _ = coordinator.replace(with: [Fixtures.carbon(13)])
        coordinator.shutdown()

        XCTAssertEqual(carbon.lifecycleMainThreads, [true, true, true])
    }

    func testCrossSourceCallbacksAreSerializedInArrivalOrder() {
        let carbon = CarbonSpy()
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
        let carbonMacro = Fixtures.carbon(13)
        let hidMacro = Fixtures.hid(21)
        _ = coordinator.replace(with: [carbonMacro, hidMacro])
        let carbonID = carbon.registrations.last!.id
        let firstStarted = expectation(description: "first callback started")
        let callbacksCompleted = expectation(description: "callbacks completed")
        callbacksCompleted.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var activeCallbacks = 0
        var maximumActiveCallbacks = 0
        var received: [UUID] = []
        coordinator.onTrigger = { id, _ in
            lock.lock()
            activeCallbacks += 1
            maximumActiveCallbacks = max(maximumActiveCallbacks, activeCallbacks)
            received.append(id)
            lock.unlock()
            if id == carbonMacro.id {
                firstStarted.fulfill()
                releaseFirst.wait()
            }
            lock.lock()
            activeCallbacks -= 1
            lock.unlock()
            callbacksCompleted.fulfill()
        }

        DispatchQueue.global().async { carbon.send(id: carbonID) }
        wait(for: [firstStarted], timeout: 1)
        DispatchQueue.global().async { hid.send(function: 21) }
        releaseFirst.signal()
        wait(for: [callbacksCompleted], timeout: 1)

        XCTAssertEqual(received, [carbonMacro.id, hidMacro.id])
        XCTAssertEqual(maximumActiveCallbacks, 1)
    }

    func testTriggerCanScheduleLifecycleOnMainAfterReturning() {
        let carbon = CarbonSpy()
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: hid
        )
        _ = coordinator.replace(with: [Fixtures.hid(21)])
        let replaced = expectation(description: "replacement completed")
        coordinator.onTrigger = { _, _ in
            DispatchQueue.main.async {
                _ = coordinator.replace(with: [Fixtures.carbon(13)])
                replaced.fulfill()
            }
        }

        DispatchQueue.global().async { hid.send(function: 21) }

        wait(for: [replaced], timeout: 1)
        XCTAssertEqual(carbon.registrationCount, 1)
    }

    func testPartialCarbonFailureAndHIDAreIndependent() {
        let carbon = CarbonSpy(failingRegistration: 2)
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
        let macros = Fixtures.enabledCarbonCarbonHID()

        let states = coordinator.replace(with: macros)

        XCTAssertEqual(carbon.registrationCount, 2)
        XCTAssertEqual(hid.usages, [21])
        XCTAssertEqual(states[macros[0].id], .registered)
        XCTAssertEqual(states[macros[1].id], .registrationFailed)
        XCTAssertEqual(states[macros[2].id], .registered)
    }

    func testSnapshotInstallerReceivesFinalRegistrationStates() {
        let carbon = CarbonSpy(failingRegistration: 2)
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let macros = [Fixtures.carbon(13), Fixtures.carbon(14)]
        var installed: [UUID: RegistrationState]?

        let returned = coordinator.replace(with: macros) { states in
            installed = states
        }

        XCTAssertEqual(installed, returned)
        XCTAssertEqual(installed?[macros[0].id], .registered)
        XCTAssertEqual(installed?[macros[1].id], .registrationFailed)
    }

    func testHIDPermissionAndStartFailuresLeaveCarbonRegistered() {
        let cases: [(HIDSpy, RegistrationState)] = [
            (HIDSpy(permission: false, starts: true), .inputMonitoringRequired),
            (HIDSpy(permission: true, starts: false), .hidStartFailed),
        ]

        for (hid, expected) in cases {
            let carbon = CarbonSpy()
            let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
            let macros = Fixtures.enabledCarbonCarbonHID()

            let states = coordinator.replace(with: macros)

            XCTAssertEqual(states[macros[0].id], .registered)
            XCTAssertEqual(states[macros[2].id], expected)
        }
    }

    func testDisabledMacroIsNotRegisteredAndShutdownReleasesBothSources() {
        var disabled = Fixtures.carbon(14)
        disabled.isEnabled = false
        let carbon = CarbonSpy()
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)

        _ = coordinator.replace(with: [Fixtures.carbon(13), disabled])
        XCTAssertEqual(carbon.registrationCount, 1)

        coordinator.shutdown()
        XCTAssertEqual(carbon.unregisterAllCount, 2)
        XCTAssertEqual(hid.stopCount, 2)
    }

    func testRemovingAllHIDStopsMonitorWithoutPermissionCheck() {
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: CarbonSpy(), hid: hid)

        _ = coordinator.replace(with: [Fixtures.hid(21)])
        _ = coordinator.replace(with: [Fixtures.carbon(13)])

        XCTAssertEqual(hid.stopCount, 2)
        XCTAssertEqual(hid.permissionChecks, 1)
    }

    func testCallbacksUseCurrentRegistrationMaps() {
        let carbon = CarbonSpy()
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
        let first = Fixtures.carbon(13)
        let second = Fixtures.hid(21)
        var triggered: [UUID] = []
        let expectation = expectation(description: "current callbacks")
        expectation.expectedFulfillmentCount = 2
        coordinator.onTrigger = { id, _ in
            triggered.append(id)
            expectation.fulfill()
        }

        _ = coordinator.replace(with: [first])
        carbon.send(id: 1)
        _ = coordinator.replace(with: [second])
        carbon.send(id: 1)
        hid.send(function: 21)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(triggered, [first.id, second.id])
    }

    func testReplacingCarbonDoesNotReuseIDOrAcceptStaleCallback() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let first = Fixtures.carbon(13)
        let second = Fixtures.carbon(14)
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }

        _ = coordinator.replace(with: [first])
        let staleID = carbon.registrations.last!.id
        _ = coordinator.replace(with: [second])
        let currentID = carbon.registrations.last!.id

        carbon.send(id: staleID)
        carbon.send(id: currentID)
        _ = coordinator.replace(with: [])

        XCTAssertNotEqual(staleID, currentID)
        XCTAssertEqual(triggered, [second.id])
    }
}
