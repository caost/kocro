import SwiftUI

struct MenuBarViewModel {
    let statuses: [OverallStatus]
    let registrations: [RegistrationState]

    var statusText: String {
        if statuses.contains(.settingsError) { return "설정 오류" }
        if statuses.contains(.accessibilityRequired) { return "Accessibility 권한 필요" }
        if statuses.contains(.inputMonitoringRequired) { return "Input Monitoring 권한 필요" }
        return "준비됨"
    }

    var registeredCount: Int {
        registrations.filter { $0 == .registered }.count
    }
}

struct AppMenuActions {
    let openSettings: () -> Void
    let openAbout: () -> Void
    let terminate: () -> Void
}

@MainActor
struct MenuBarView: View {
    @ObservedObject var app: AppController
    let actions: AppMenuActions
    let refresh: () -> Void

    var body: some View {
        Text(app.statusText)
        Text("등록된 매크로 \(app.registeredCount)개")

        if let result = app.lastResult {
            Text(lastResultText(result))
        }

        if app.measurementEnabled {
            Text(
                "측정 \(app.measurementCount)/100 · "
                    + (app.queueIsIdle ? "큐 비어 있음" : "게시 중")
            )
        }

        Divider()

        if !app.permissionState.accessibility {
            Button("Accessibility 권한 안내") {
                app.requestAccessibility()
            }
            Button("Accessibility 설정 열기") {
                app.openPrivacySettings(.accessibility)
            }
        }

        if app.showsInputMonitoringActions {
            Button("Input Monitoring 권한 요청") {
                app.requestInputMonitoring()
            }
            Button("Input Monitoring 설정 열기") {
                app.openPrivacySettings(.inputMonitoring)
            }
        }

        Button("설정…", action: actions.openSettings)
        Button("Kocro 정보", action: actions.openAbout)

        Divider()

        Button("종료", action: actions.terminate)
        .onAppear(perform: refresh)
    }

    private func lastResultText(_ result: ExecutionResult) -> String {
        let identifier = result.id.uuidString.prefix(8)
        let kind: String
        switch result.kind {
        case .postingRequested:
            kind = "게시 요청 완료"
        case .accessibilityRequired:
            kind = "Accessibility 권한 필요"
        case .eventCreationFailed:
            kind = "이벤트 생성 실패"
        case .missingDefinition:
            kind = "매크로 정의 없음"
        }
        return "매크로 \(identifier) · \(result.shortcut) · \(kind) · \(result.date.formatted())"
    }
}
