import Carbon
import XCTest
@testable import Kocro

final class CarbonHotKeySourceTests: XCTestCase {
    func testRegistrationFailureReasonReachesBadgeWithoutBecomingConflict() {
        for (status, label): (OSStatus, String) in [
            (OSStatus(eventHotKeyExistsErr), "충돌"),
            (OSStatus(paramErr), "등록 실패"),
        ] {
            let api = CarbonHotKeyAPISpy()
            api.registrationStatus = status
            let coordinator = ShortcutCoordinator(carbon: CarbonHotKeySource(api: api))
            let macro = Fixtures.carbon(13)
            let candidate = coordinator.prepareReplacement(with: .init(macros: [macro]))
            XCTAssertFalse(candidate.settings.macros[0].isEnabled)
            XCTAssertEqual(MacroStatusBadge.resolve(
                isEnabled: false, isDirty: true, registration: candidate.states[macro.id]
            ).label, label)
            coordinator.cancel(candidate)
        }
    }

    func testRegistrationUsesExclusiveOptionAndReturnsStatusResult() {
        let api = CarbonHotKeyAPISpy()
        let source = CarbonHotKeySource(api: api)
        let shortcut = ShortcutDefinition(key: .function(13), modifiers: [])

        api.registrationStatus = noErr
        XCTAssertEqual(source.register(id: 1, shortcut: shortcut), .registered)
        XCTAssertEqual(api.options, [UInt32(kEventHotKeyExclusive)])

        api.registrationStatus = OSStatus(eventHotKeyExistsErr)
        XCTAssertEqual(source.register(id: 2, shortcut: shortcut), .conflict)
        XCTAssertEqual(
            api.options,
            [UInt32(kEventHotKeyExclusive), UInt32(kEventHotKeyExclusive)]
        )
    }

    func testBackgroundFinalReleaseCleansUpOnMainThread() {
        let api = CarbonHotKeyAPISpy()
        let unregistered = expectation(description: "hot key unregistered")
        api.onUnregister = {
            XCTAssertTrue(Thread.isMainThread)
            unregistered.fulfill()
        }
        let box: ObjectReleaseBox = {
            let source = CarbonHotKeySource(api: api)
            XCTAssertEqual(
                source.register(
                    id: 1,
                    shortcut: .init(key: .function(13), modifiers: [])
                ),
                .registered
            )
            return ObjectReleaseBox(source)
        }()

        DispatchQueue.global().async {
            box.releaseValue()
        }

        wait(for: [unregistered], timeout: 1)
    }

    func testDuplicateRegistrationIDFailsAndIndividualUnregisterReleasesOnlyItsReference() {
        let api = CarbonHotKeyAPISpy()
        let source = CarbonHotKeySource(api: api)

        XCTAssertEqual(source.register(id: 1, shortcut: .init(key: .function(13), modifiers: [])), .registered)
        XCTAssertEqual(source.register(id: 2, shortcut: .init(key: .function(14), modifiers: [])), .registered)
        XCTAssertEqual(source.register(id: 1, shortcut: .init(key: .function(15), modifiers: [])), .registrationFailed)

        source.unregister(id: 1)
        XCTAssertEqual(api.unregisteredReferences, [EventHotKeyRef(bitPattern: 1)!])

        source.unregisterAll()
        XCTAssertEqual(
            api.unregisteredReferences,
            [EventHotKeyRef(bitPattern: 1)!, EventHotKeyRef(bitPattern: 2)!]
        )
        XCTAssertEqual(api.registeredIDs, [1, 2])
    }
}
