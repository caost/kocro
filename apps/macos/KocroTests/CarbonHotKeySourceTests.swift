import Carbon
import XCTest
@testable import Kocro

final class CarbonHotKeySourceTests: XCTestCase {
    func testRegistrationUsesExclusiveOptionAndReturnsStatusResult() {
        let api = CarbonHotKeyAPISpy()
        let source = CarbonHotKeySource(api: api)
        let shortcut = ShortcutDefinition(key: .function(13), modifiers: [])

        api.registrationStatus = noErr
        XCTAssertTrue(source.register(id: 1, shortcut: shortcut))
        XCTAssertEqual(api.options, [UInt32(kEventHotKeyExclusive)])

        api.registrationStatus = OSStatus(eventHotKeyExistsErr)
        XCTAssertFalse(source.register(id: 2, shortcut: shortcut))
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
            XCTAssertTrue(
                source.register(
                    id: 1,
                    shortcut: .init(key: .function(13), modifiers: [])
                )
            )
            return ObjectReleaseBox(source)
        }()

        DispatchQueue.global().async {
            box.releaseValue()
        }

        wait(for: [unregistered], timeout: 1)
    }
}
