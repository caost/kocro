import SwiftUI

enum MenuItemKind: Hashable {
    case status
    case macroList
    case recentExecution
    case settings
    case about
    case quit
}

struct MenuMacroItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let shortcut: String

    var displayName: String { "\(title) · \(shortcut)" }
}

struct MenuMacroGroup: Equatable, Identifiable {
    let id: Int
    let title: String
    let items: [MenuMacroItem]
}

struct MenuMacroLayout: Equatable {
    let items: [MenuMacroItem]
    let groups: [MenuMacroGroup]

    var emptyMessage: String? {
        items.isEmpty && groups.isEmpty ? "실행 가능한 매크로 없음" : nil
    }
}

struct MenuBarViewModel {
    static let macroGroupSize = 10

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

    static func executableMacros(
        macros: [MacroDefinition],
        registration: [UUID: RegistrationState]
    ) -> [MenuMacroItem] {
        macros.filter {
            $0.isExecutable(registration: registration[$0.id])
        }.map {
            MenuMacroItem(
                id: $0.id,
                title: displayTitle(id: $0.id, title: $0.title),
                shortcut: $0.shortcut.displayName
            )
        }
    }

    static func macroLayout(items: [MenuMacroItem]) -> MenuMacroLayout {
        let flat = Array(items.prefix(macroGroupSize))
        let groups = stride(from: macroGroupSize, to: items.count, by: macroGroupSize).map { start in
            let end = min(start + macroGroupSize, items.count)
            return MenuMacroGroup(
                id: start,
                title: "매크로 \(start + 1)–\(end)",
                items: Array(items[start..<end])
            )
        }
        return MenuMacroLayout(items: flat, groups: groups)
    }

    private static func displayTitle(id: UUID, title: String) -> String {
        title.isEmpty ? "매크로 \(id.uuidString.prefix(8))" : title
    }

    static func recentTitle(
        result: ExecutionResult,
        macros: [MacroDefinition]
    ) -> String {
        displayTitle(
            id: result.id,
            title: macros.first(where: { $0.id == result.id })?.title ?? ""
        )
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
            ? [.status, .macroList, .recentExecution, .settings, .about, .quit]
            : [.status, .macroList, .settings, .about, .quit]
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

        case .macroList:
            Divider()
            macroList

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

    @ViewBuilder
    private var macroList: some View {
        let layout = MenuBarViewModel.macroLayout(
            items: MenuBarViewModel.executableMacros(
                macros: app.runtimeMacros,
                registration: app.registration
            )
        )
        if let message = layout.emptyMessage {
            Text(message).disabled(true)
        }
        ForEach(layout.items) { item in
            macroButton(item)
        }
        ForEach(layout.groups) { group in
            Menu {
                ForEach(group.items) { item in
                    macroButton(item)
                }
            } label: {
                Text(verbatim: group.title)
            }
        }
    }

    private func macroButton(_ item: MenuMacroItem) -> some View {
        Button {
            app.runMacro(id: item.id)
        } label: {
            Text(verbatim: item.displayName)
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
