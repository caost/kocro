import ServiceManagement
import XCTest
@testable import Kocro

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testDefaultOffAndExplicitToggle() throws {
        let service = LoginServiceSpy(status: .notRegistered)
        let controller = LoginItemController(service: service)

        XCTAssertFalse(controller.isEnabled)
        try controller.setEnabled(true)
        try controller.setEnabled(false)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testFailedUserToggleSurfacesErrorAndKeepsServiceState() {
        let service = LoginServiceSpy(status: .notRegistered)
        service.registerError = LoginServiceSpy.Failure.denied
        let controller = LoginItemController(service: service)

        controller.setEnabledFromUI(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(service.registerCount, 1)
    }

    func testApprovalRequiredStatusIsShownInsteadOfAppearingEnabled() throws {
        let service = LoginServiceSpy(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let controller = LoginItemController(service: service)

        try controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.errorMessage, "시스템 설정에서 로그인 항목을 승인해 주세요")
    }

    func testRefreshTracksExternalApprovalWithoutRegisteringAgain() {
        let service = LoginServiceSpy(status: .requiresApproval)
        let controller = LoginItemController(service: service)
        XCTAssertFalse(controller.isEnabled)

        service.status = .enabled
        controller.refreshStatus()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    func testRefreshTracksExternalRemovalWithoutUnregisteringAgain() {
        let service = LoginServiceSpy(status: .enabled)
        let controller = LoginItemController(service: service)
        XCTAssertTrue(controller.isEnabled)

        service.status = .notRegistered
        controller.refreshStatus()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }
}
