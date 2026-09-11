import AppKit
import SwiftUI

@MainActor
struct GeneralSettingsViewModel {
    private let app: AppController
    private let login: LoginItemController
    private let beginMacroImportAction: () -> Void
    private let beginMacroExportAction: () -> Void

    init(
        app: AppController,
        login: LoginItemController,
        beginMacroImport: @escaping () -> Void = {},
        beginMacroExport: @escaping () -> Void = {}
    ) {
        self.app = app
        self.login = login
        beginMacroImportAction = beginMacroImport
        beginMacroExportAction = beginMacroExport
    }

    var loginEnabled: Bool { login.isEnabled }
    var loginErrorMessage: String? { login.errorMessage }
    var accessibilityGranted: Bool { app.permissionState.accessibility }

    func setLoginEnabled(_ enabled: Bool) {
        login.setEnabledReportingError(enabled)
    }

    func requestAccessibility() { app.requestAccessibility() }
    func openAccessibilitySettings() { app.openPrivacySettings(.accessibility) }
    func beginMacroImport() { beginMacroImportAction() }
    func beginMacroExport() { beginMacroExportAction() }
    func refreshPermissions() {
        app.refreshPermissions(reconcileShortcuts: false)
    }
}

struct GeneralSettingsView: View {
    let model: GeneralSettingsViewModel
    let transferMessage: String?
    let transferFailed: Bool

    init(
        model: GeneralSettingsViewModel,
        transferMessage: String? = nil,
        transferFailed: Bool = false
    ) {
        self.model = model
        self.transferMessage = transferMessage
        self.transferFailed = transferFailed
    }

    var body: some View {
        Form {
            Section("로그인") {
                Toggle(
                    "로그인 시 실행",
                    isOn: Binding(
                        get: { model.loginEnabled },
                        set: model.setLoginEnabled
                    )
                )
                if let message = model.loginErrorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }

            Section("Accessibility") {
                permissionStatus(granted: model.accessibilityGranted)
                Button("권한 안내 요청", action: model.requestAccessibility)
                    .accessibilityLabel("Accessibility 권한 안내 요청")
                Button("시스템 설정 열기", action: model.openAccessibilitySettings)
                    .accessibilityLabel("Accessibility 시스템 설정 열기")
            }

            Section("매크로 가져오기 및 내보내기") {
                HStack {
                    Button("가져오기…", action: model.beginMacroImport)
                    Button("내보내기…", action: model.beginMacroExport)
                }
                Text("내보내기는 마지막 저장된 전체 매크로를 포함합니다. 저장 전 편집은 포함하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let transferMessage {
                    Text(transferMessage)
                        .foregroundStyle(transferFailed ? Color.red : Color.secondary)
                }
            }

            Section("민감한 정보") {
                Text("비밀번호, API 키와 인증 토큰을 매크로에 저장하지 마세요.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear(perform: model.refreshPermissions)
    }

    private func permissionStatus(granted: Bool) -> some View {
        Text(granted ? "허용됨" : "권한 필요")
            .accessibilityLabel(granted ? "권한 허용됨" : "권한 필요")
    }
}
