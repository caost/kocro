import XCTest
@testable import Kocro

final class PermissionClientTests: XCTestCase {
    func testRefreshChecksAccessibilityWithoutPromptAndSkipsInputMonitoringWhenHIDIsNotNeeded() {
        let api = PermissionAPISpy(accessibility: false, input: false)
        let client = PermissionClient(api: api)

        let state = client.refresh(needsHID: false)

        XCTAssertEqual(api.accessibilityChecks, [false])
        XCTAssertEqual(api.accessibilityPrompts, 0)
        XCTAssertEqual(api.inputChecks, 0)
        XCTAssertFalse(state.accessibility)
        XCTAssertNil(state.inputMonitoring)
    }

    func testExplicitAccessibilityRequestDoesNotMutateCachedStateUntilRefresh() {
        let api = PermissionAPISpy(accessibility: true, input: false)
        let client = PermissionClient(api: api)

        client.requestAccessibility()

        XCTAssertEqual(api.accessibilityPrompts, 1)
        XCTAssertFalse(client.state.accessibility)
        XCTAssertTrue(client.refresh(needsHID: false).accessibility)
    }

    func testRefreshChecksInputMonitoringOnlyWhenHIDIsNeeded() {
        let api = PermissionAPISpy(accessibility: true, input: true)
        let client = PermissionClient(api: api)

        let state = client.refresh(needsHID: true)

        XCTAssertEqual(api.inputChecks, 1)
        XCTAssertEqual(state.inputMonitoring, true)
    }

    func testCurrentAccessibilityChecksSystemInsteadOfReturningCachedState() {
        let api = PermissionAPISpy(accessibility: true, input: false)
        let client = PermissionClient(api: api)
        _ = client.refresh(needsHID: false)
        api.accessibility = false

        XCTAssertFalse(client.currentAccessibility())
        XCTAssertEqual(api.accessibilityChecks, [false])
        XCTAssertEqual(api.currentAccessibilityChecks, 1)
    }

    func testExplicitInputMonitoringRequestDoesNotMutateCachedStateUntilRefresh() {
        let api = PermissionAPISpy(accessibility: false, input: true)
        let client = PermissionClient(api: api)

        client.requestInputMonitoring()

        XCTAssertEqual(api.inputRequests, 1)
        XCTAssertNil(client.state.inputMonitoring)
    }

    func testOpenSettingsRoutesRequestedPrivacyKind() {
        let api = PermissionAPISpy(accessibility: false, input: false)
        let client = PermissionClient(api: api)

        client.openSettings(.accessibility)
        client.openSettings(.inputMonitoring)

        XCTAssertEqual(api.openedSettings, [.accessibility, .inputMonitoring])
    }

    func testSystemSettingsURLsTargetExactPrivacyPanes() {
        XCTAssertEqual(
            SystemPermissionAPI.settingsURL(for: .accessibility).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            SystemPermissionAPI.settingsURL(for: .inputMonitoring).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
    }
}
