import ServiceManagement
import SwiftUI

@MainActor
protocol LoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: LoginService

    init(service: LoginService) {
        self.service = service
        isEnabled = false
        errorMessage = nil
        refreshStatus()
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            let status = service.status
            apply(status)
            if enabled, status == .requiresApproval {
                errorMessage = "시스템 설정에서 로그인 항목을 승인해 주세요"
            } else if isEnabled != enabled {
                errorMessage = "로그인 항목 변경 상태를 확인해 주세요"
            }
        } catch {
            isEnabled = service.status == .enabled
            errorMessage = "로그인 항목을 변경하지 못했습니다 (\(String(describing: type(of: error))))"
            throw error
        }
    }

    /// 실패를 errorMessage 로만 알리고 던지지 않는다. 토글처럼 되돌릴 곳이 없는 호출자를 위한 경로다.
    func setEnabledReportingError(_ enabled: Bool) {
        do {
            try setEnabled(enabled)
        } catch {
            // setEnabled 가 실제 서비스 상태를 유지한 채 errorMessage 를 이미 기록했다.
        }
    }

    func refreshStatus() {
        apply(service.status)
    }

    private func apply(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            isEnabled = true
            errorMessage = nil
        case .requiresApproval:
            isEnabled = false
            errorMessage = "시스템 설정에서 로그인 항목을 승인해 주세요"
        case .notRegistered:
            isEnabled = false
            errorMessage = nil
        case .notFound:
            isEnabled = false
            errorMessage = "로그인 항목을 찾지 못했습니다"
        @unknown default:
            isEnabled = false
            errorMessage = "로그인 항목 상태를 확인할 수 없습니다"
        }
    }
}

@MainActor
final class MainAppLoginService: LoginService {
    private let service: SMAppService

    init(service: SMAppService = SMAppService.mainApp) {
        self.service = service
    }

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
