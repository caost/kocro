import XCTest
@testable import Kocro

final class ShortcutCoordinatorTests: XCTestCase {
    func testCarbonOnlyCoordinatorRegistersAndShutsDownWithoutSecondaryInputSource() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)

        let states = coordinator.replace(with: [Fixtures.carbon(13)])
        coordinator.shutdown()

        XCTAssertEqual(Array(states.values), [.registered])
        XCTAssertEqual(carbon.unregisterAllCount, 1)
    }

    func testRecordedOptionCommandIRegistersAndRoutesThroughCarbon() throws {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let recorded = try XCTUnwrap(
            KeyRecorderTranslator.shortcut(
                keyCode: 34,
                modifiers: [.option, .command]
            )
        )
        let macro = Fixtures.macro(
            text: "approved",
            shortcut: recorded
        )
        var triggered: [UUID] = []
        coordinator.onTrigger = { id, _ in triggered.append(id) }

        let states = coordinator.replace(with: [macro])
        carbon.send(id: carbon.registrations[0].id)

        XCTAssertEqual(states[macro.id], .registered)
        XCTAssertEqual(
            carbon.registrations[0].shortcut.registrationIdentity,
            .init(key: .carbon(34), modifiers: [.option, .command])
        )
        XCTAssertEqual(triggered, [macro.id])
    }

    func testCarbonLifecycleRunsOnMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
        _ = coordinator.replace(with: [Fixtures.carbon(13)])
        coordinator.shutdown()

        XCTAssertFalse(carbon.lifecycleMainThreads.isEmpty)
        XCTAssertTrue(carbon.lifecycleMainThreads.allSatisfy { $0 })
    }

    func testSnapshotInstallerReceivesFinalRegistrationStates() {
        let carbon = CarbonSpy(failingRegistration: 2)
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let macros = [Fixtures.carbon(13), Fixtures.carbon(14)]
        var installed: [UUID: RegistrationState]?

        let returned = coordinator.replace(with: macros) { states in
            installed = states
        }

        XCTAssertEqual(installed, returned)
        XCTAssertEqual(installed?[macros[0].id], .registered)
        XCTAssertEqual(installed?[macros[1].id], .registrationFailed)
    }

    func testDisabledMacroIsNotRegisteredAndShutdownReleasesCarbon() {
        var disabled = Fixtures.carbon(14)
        disabled.isEnabled = false
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)

        _ = coordinator.replace(with: [Fixtures.carbon(13), disabled])
        XCTAssertEqual(carbon.registrationCount, 1)

        coordinator.shutdown()
        XCTAssertEqual(carbon.unregisterAllCount, 1)
    }

    func testReplacingCarbonDoesNotReuseIDOrAcceptStaleCallback() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
        let carbonMacro = Fixtures.carbon(13)
        let conflicted = Fixtures.carbon(14)

        let candidate = coordinator.prepareReplacement(
            with: AppSettings(macros: [carbonMacro, conflicted])
        )

        XCTAssertEqual(candidate.states[carbonMacro.id], .registered)
        XCTAssertEqual(candidate.states[conflicted.id], .registrationFailed)
        XCTAssertEqual(candidate.settings.macros.map(\.isEnabled), [true, false])
        coordinator.cancel(candidate)
    }

    func testCommitThenCancelDoesNotReleaseActiveCandidateRegistration() {
        let carbon = CarbonSpy()
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let first = ShortcutCoordinator(carbon: firstCarbon)
        let second = ShortcutCoordinator(carbon: secondCarbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
        let coordinator = ShortcutCoordinator(carbon: carbon)
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
