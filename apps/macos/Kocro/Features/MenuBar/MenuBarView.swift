import SwiftUI

enum MenuItemKind: Hashable {
    case status
    case recentExecution
    case settings
    case about
    case quit
}

struct MenuBarViewModel {
    let statuses: [OverallStatus]
    let registrations: [RegistrationState]

    var statusText: String {
        if statuses.contains(.settingsError) { return "설정 오류" }
        if statuses.contains(.accessibilityRequired) { return "Accessibility 권한 필요" }
        return "준비됨"
    }

    var registeredCount: Int {
        registrations.filter { $0 == .registered }.count
    }

    static func recentTitle(
        result: ExecutionResult,
        macros: [MacroDefinition]
    ) -> String {
        guard let title = macros.first(where: { $0.id == result.id })?.title,
              !title.isEmpty else {
            return "매크로 \(result.id.uuidString.prefix(8))"
        }
        return title
    }

    static func resultText(for kind: ExecutionResultKind) -> String {
        switch kind {
        case .postingRequested:
            return "게시 요청 완료"
        case .accessibilityRequired:
            return "Accessibility 권한 필요"
        case .eventCreationFailed:
            return "이벤트 생성 실패"
        case .missingDefinition:
            return "매크로 정의 없음"
        }
    }

    static func recentDetail(
        result: ExecutionResult,
        relativeDateText: String
    ) -> String {
        "\(result.shortcut) · \(resultText(for: result.kind)) · \(relativeDateText)"
    }

    static func menuItems(hasRecentResult: Bool) -> [MenuItemKind] {
        hasRecentResult
            ? [.status, .recentExecution, .settings, .about, .quit]
            : [.status, .settings, .about, .quit]
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
        ForEach(
            MenuBarViewModel.menuItems(hasRecentResult: app.lastResult != nil),
            id: \.self,
            content: menuItem
        )
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func menuItem(_ item: MenuItemKind) -> some View {
        switch item {
        case .status:
            Text(app.statusText)
            Text("등록된 매크로 \(app.registeredCount)개")

            if !app.permissionState.accessibility {
                Button("Accessibility 권한 안내") {
                    app.requestAccessibility()
                }
                Button("Accessibility 설정 열기") {
                    app.openPrivacySettings(.accessibility)
                }
            }

            if app.measurementEnabled {
                Text(
                    "측정 \(app.measurementCount)/100 · "
                        + (app.queueIsIdle ? "큐 비어 있음" : "게시 중")
                )
            }

        case .recentExecution:
            if let result = app.lastResult {
                Divider()
                Text(MenuBarViewModel.recentTitle(result: result, macros: app.runtimeMacros))
                Text(recentDetail(result))
            }

        case .settings:
            Divider()
            Button("설정…", action: actions.openSettings)
        case .about:
            Button("Kocro 정보…", action: actions.openAbout)
        case .quit:
            Divider()
            Button("Kocro 종료", action: actions.terminate)
        }
    }

    private func recentDetail(_ result: ExecutionResult) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return MenuBarViewModel.recentDetail(
            result: result,
            relativeDateText: formatter.localizedString(for: result.date, relativeTo: Date())
        )
    }
}
