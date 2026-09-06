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

        XCTAssertFalse(carbon.lifecycleMainThreads.isEmpty)
        XCTAssertTrue(carbon.lifecycleMainThreads.allSatisfy { $0 })
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
        XCTAssertEqual(carbon.unregisterAllCount, 1)
        XCTAssertEqual(hid.stopCount, 1)
    }

    func testRemovingAllHIDStopsMonitorWithoutPermissionCheck() {
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: CarbonSpy(), hid: hid)

        _ = coordinator.replace(with: [Fixtures.hid(21)])
        _ = coordinator.replace(with: [Fixtures.carbon(13)])

        XCTAssertEqual(hid.stopCount, 1)
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

    func testPrepareReusesRegistrationIdentityForNewUUIDAndSwap() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let firstF13 = Fixtures.carbon(13)
        let firstF14 = Fixtures.carbon(14)
        _ = coordinator.replace(with: [firstF13, firstF14])
        let originalIDs = carbon.registrations.map(\.id)
        let newF13 = Fixtures.carbon(13)
        var swappedF14 = firstF13
        swappedF14.shortcut = firstF14.shortcut

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [swappedF14, newF13])
        )

        XCTAssertEqual(carbon.registrations.map(\.id), originalIDs)
        coordinator.commit(candidate)
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }
        carbon.send(id: originalIDs[0])
        carbon.send(id: originalIDs[1])
        XCTAssertEqual(triggered, [newF13.id, swappedF14.id])
    }

    func testProvisionalCarbonRegistrationIsUnroutedUntilCommit() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let old = Fixtures.carbon(13)
        _ = coordinator.replace(with: [old])
        let added = Fixtures.carbon(15)
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [old, added])
        )
        let existingID = carbon.registrations.first!.id
        let provisionalID = carbon.registrations.last!.id
        carbon.send(id: existingID)
        carbon.send(id: provisionalID)
        XCTAssertEqual(triggered, [old.id])

        coordinator.commit(candidate)
        carbon.send(id: provisionalID)
        XCTAssertEqual(triggered, [old.id, added.id])
    }

    func testCancelReleasesOnlyCandidateRegistrationsAndPreservesCurrentRoutes() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let oldF13 = Fixtures.carbon(13)
        let oldF14 = Fixtures.carbon(14)
        _ = coordinator.replace(with: [oldF13, oldF14])
        let oldIDs = carbon.registrations.map(\.id)
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [Fixtures.carbon(15)])
        )
        let provisionalID = carbon.registrations.last!.id
        coordinator.cancel(candidate)

        XCTAssertEqual(carbon.unregisteredIDs, [provisionalID])
        carbon.send(id: oldIDs[0])
        carbon.send(id: oldIDs[1])
        carbon.send(id: provisionalID)
        XCTAssertEqual(triggered, [oldF13.id, oldF14.id])
    }

    func testCarbonCollisionDisablesOnlyFailedCandidateMacro() {
        let carbon = CarbonSpy(failingRegistration: 2)
        let hid = HIDSpy(permission: false, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
        let carbonMacro = Fixtures.carbon(13)
        let conflicted = Fixtures.carbon(14)
        let hidMacro = Fixtures.hid(21)

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [carbonMacro, conflicted, hidMacro])
        )

        XCTAssertEqual(candidate.states[carbonMacro.id], .registered)
        XCTAssertEqual(candidate.states[conflicted.id], .registrationFailed)
        XCTAssertEqual(candidate.states[hidMacro.id], .inputMonitoringRequired)
        XCTAssertEqual(candidate.settings.macros.map(\.isEnabled), [true, false, true])
        coordinator.cancel(candidate)
    }

    func testCancelDoesNotReplaceActiveHIDGeneration() {
        let carbon = CarbonSpy()
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: carbon, hid: hid)
        let current = Fixtures.hid(21)
        _ = coordinator.replace(with: [current])
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [Fixtures.hid(22)])
        )
        coordinator.cancel(candidate)
        hid.send(function: 21)

        XCTAssertEqual(triggered, [current.id])
        XCTAssertEqual(hid.stopCount, 0)
        XCTAssertEqual(hid.usages, [21])
    }

    func testCommitWithoutHIDPermissionStopsThePreviousGeneration() {
        let hid = HIDSpy(permission: true, starts: true)
        let coordinator = ShortcutCoordinator(carbon: CarbonSpy(), hid: hid)
        _ = coordinator.replace(with: [Fixtures.hid(21)])
        hid.permission = false

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [Fixtures.hid(22)])
        )
        coordinator.commit(candidate)

        XCTAssertEqual(hid.stopCount, 1)
    }

    func testCommitThenCancelDoesNotReleaseActiveCandidateRegistration() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let macro = Fixtures.carbon(15)
        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [macro])
        )
        let registrationID = carbon.registrations.last!.id

        coordinator.commit(candidate)
        coordinator.cancel(candidate)

        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }
        carbon.send(id: registrationID)
        XCTAssertEqual(triggered, [macro.id])
        XCTAssertTrue(carbon.unregisteredIDs.isEmpty)
    }

    func testCancelThenCommitDoesNotPublishReleasedCandidateRoute() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let current = Fixtures.carbon(13)
        _ = coordinator.replace(with: [current])
        let currentID = carbon.registrations.last!.id
        let replacement = Fixtures.carbon(15)
        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [replacement])
        )
        let releasedID = carbon.registrations.last!.id

        coordinator.cancel(candidate)
        XCTAssertNil(coordinator.commit(candidate))

        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }
        carbon.send(id: currentID)
        carbon.send(id: releasedID)
        XCTAssertEqual(triggered, [current.id])
        XCTAssertEqual(carbon.unregisteredIDs, [releasedID])
    }

    func testRepeatedTerminalCallsConsumeCandidateOnlyOnce() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [Fixtures.carbon(15)])
        )
        var snapshotInstallCount = 0

        coordinator.commit(candidate) { _ in snapshotInstallCount += 1 }
        coordinator.commit(candidate) { _ in snapshotInstallCount += 1 }
        coordinator.cancel(candidate)
        coordinator.cancel(candidate)

        XCTAssertEqual(snapshotInstallCount, 1)
        XCTAssertTrue(carbon.unregisteredIDs.isEmpty)
    }

    func testCrossCoordinatorCandidateUseCannotMutateRegistrationsOrRoutes() {
        let firstCarbon = CarbonSpy()
        let secondCarbon = CarbonSpy()
        let first = ShortcutCoordinator(
            carbon: firstCarbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let second = ShortcutCoordinator(
            carbon: secondCarbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let firstMacro = Fixtures.carbon(15)
        let secondMacro = Fixtures.carbon(13)
        let candidate = first.prepareReplacement(
            with: AppSettings(macros: [firstMacro])
        )
        _ = second.replace(with: [secondMacro])
        let secondRegistrationID = secondCarbon.registrations.last!.id

        second.cancel(candidate)
        XCTAssertNil(second.commit(candidate))

        var triggered: [UUID] = []
        second.onTrigger = { id, _ in triggered.append(id) }
        secondCarbon.send(id: secondRegistrationID)
        XCTAssertEqual(triggered, [secondMacro.id])
        XCTAssertTrue(secondCarbon.unregisteredIDs.isEmpty)
        first.cancel(candidate)
    }

    func testNewPrepareSupersedesAndReleasesPreviousUnresolvedCandidate() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let firstCandidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [Fixtures.carbon(15)])
        )
        let firstID = carbon.registrations.last!.id
        let replacement = Fixtures.carbon(15)

        let secondCandidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [replacement])
        )
        let secondID = carbon.registrations.last!.id
        XCTAssertNil(coordinator.commit(firstCandidate))
        coordinator.cancel(firstCandidate)
        coordinator.commit(secondCandidate)

        XCTAssertEqual(carbon.unregisteredIDs, [firstID])
        XCTAssertNotEqual(firstID, secondID)
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }
        carbon.send(id: secondID)
        XCTAssertEqual(triggered, [replacement.id])
    }

    func testAbandonedCandidateReleasesItsProvisionalRegistration() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        var candidate: (any ShortcutReplacementCandidate)? = coordinator.prepareReplacement(
            with: AppSettings(macros: [Fixtures.carbon(15)])
        )
        let registrationID = carbon.registrations.last!.id
        XCTAssertNotNil(candidate?.settings)

        candidate = nil

        XCTAssertEqual(carbon.unregisteredIDs, [registrationID])
    }

    func testCandidateAbandonedOnBackgroundReleasesRegistrationOnMain() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(
            carbon: carbon,
            hid: HIDSpy(permission: true, starts: true)
        )
        let unregistered = expectation(description: "candidate registration released")
        carbon.onUnregisterID = { _ in
            XCTAssertTrue(Thread.isMainThread)
            unregistered.fulfill()
        }
        let box: ObjectReleaseBox = {
            let candidate = coordinator.prepareReplacement(
                with: AppSettings(macros: [Fixtures.carbon(15)])
            )
            return ObjectReleaseBox(candidate)
        }()

        DispatchQueue.global().async {
            box.releaseValue()
        }

        wait(for: [unregistered], timeout: 1)
    }
}
