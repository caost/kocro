import AppKit
import XCTest
@testable import Kocro

@MainActor
final class GeneralSettingsViewTests: XCTestCase {
    func testGeneralSettingsExposesLoginAndAccessibility() {
        let permissions = GeneralPermissionSpy(
            state: .init(accessibility: false)
        )
        let app = AppController(
            store: StoreSpy(loadResult: .success(.init(macros: []))),
            shortcuts: ShortcutSpy(),
            permissions: permissions,
            queue: QueueSpy()
        )
        app.start()
        let login = LoginItemController(service: LoginServiceSpy(status: .notRegistered))
        let general = GeneralSettingsViewModel(app: app, login: login)

        XCTAssertFalse(general.loginEnabled)
        XCTAssertNil(general.loginErrorMessage)
        XCTAssertFalse(general.accessibilityGranted)

        general.requestAccessibility()
        general.openAccessibilitySettings()
        XCTAssertEqual(permissions.accessibilityRequestCount, 1)
        XCTAssertEqual(permissions.openedSettings, [.accessibility])
    }

    func testActiveRefreshReconcilesRuntimeShortcuts() {
        let runtime = AppSettings(macros: [Fixtures.carbon(13)])
        let permissions = PermissionSpy(state: .init(accessibility: true))
        let shortcuts = ShortcutSpy()
        let app = AppController(
            store: StoreSpy(loadResult: .success(runtime)),
            shortcuts: shortcuts,
            permissions: permissions,
            queue: QueueSpy()
        )
        app.start()
        permissions.refreshedState = .init(accessibility: true)

        app.refreshPermissions(reconcileShortcuts: true)

        XCTAssertEqual(shortcuts.commitCount, 2)
        XCTAssertEqual(shortcuts.prepareCalls.last, runtime)
    }
}

private final class GeneralPermissionSpy: PermissionServing {
    var state: PermissionState
    private(set) var accessibilityRequestCount = 0
    private(set) var openedSettings: [PrivacyKind] = []

    init(state: PermissionState) {
        self.state = state
    }

    func refresh() -> PermissionState { state }
    func requestAccessibility() { accessibilityRequestCount += 1 }
    func openSettings(_ kind: PrivacyKind) { openedSettings.append(kind) }
    func currentAccessibility() -> Bool { state.accessibility }
}
