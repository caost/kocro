import XCTest
@testable import Kocro

final class PermissionClientTests: XCTestCase {
    func testRefreshChecksAccessibilityWithoutPrompt() {
        let api = PermissionAPISpy(accessibility: false)
        let client = PermissionClient(api: api)

        let state = client.refresh()

        XCTAssertEqual(api.accessibilityChecks, [false])
        XCTAssertEqual(api.accessibilityPrompts, 0)
        XCTAssertFalse(state.accessibility)
    }

    func testExplicitAccessibilityRequestDoesNotMutateCachedStateUntilRefresh() {
        let api = PermissionAPISpy(accessibility: true)
        let client = PermissionClient(api: api)

        client.requestAccessibility()

        XCTAssertEqual(api.accessibilityPrompts, 1)
        XCTAssertFalse(client.state.accessibility)
        XCTAssertTrue(client.refresh().accessibility)
    }

    func testCurrentAccessibilityChecksSystemInsteadOfReturningCachedState() {
        let api = PermissionAPISpy(accessibility: true)
        let client = PermissionClient(api: api)
        _ = client.refresh()
        api.accessibility = false

        XCTAssertFalse(client.currentAccessibility())
        XCTAssertEqual(api.accessibilityChecks, [false])
        XCTAssertEqual(api.currentAccessibilityChecks, 1)
    }

    func testOpenSettingsRoutesAccessibilityPrivacyKind() {
        let api = PermissionAPISpy(accessibility: false)
        let client = PermissionClient(api: api)

        client.openSettings(.accessibility)

        XCTAssertEqual(api.openedSettings, [.accessibility])
    }

    func testSystemSettingsURLTargetsAccessibilityPane() {
        XCTAssertEqual(
            SystemPermissionAPI.settingsURL(for: .accessibility).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
