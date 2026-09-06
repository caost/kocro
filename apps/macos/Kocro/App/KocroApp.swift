import AppKit
import SwiftUI

@MainActor
struct LegacySettingsWindowAction {
    let sendAction: (Selector) -> Bool

    init(sendAction: @escaping (Selector) -> Bool) {
        self.sendAction = sendAction
    }

    func open() {
        _ = sendAction(Selector(("showPreferencesWindow:")))
    }

    static var application: Self {
        Self { selector in
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }
}

@MainActor
final class AppDependencies: ObservableObject {
    let controller: AppController
    let settings: SettingsViewModel
    let login: LoginItemController

    private var terminationObserver: NSObjectProtocol?

    init() {
        let validator = SettingsValidator()
        let store = JSONSettingsStore(
            file: ApplicationSupportSettingsFile(),
            validator: validator
        )
        let carbon = CarbonHotKeySource()
        let hid = HIDFunctionKeySource()
        let permissions = PermissionClient(api: SystemPermissionAPI())
        let measurementEnabled = MeasurementSession.isRequested()
        let measurement = measurementEnabled
            ? MeasurementSession(enabled: true)
            : nil
        let poster = CoreGraphicsBatchPoster(measurement: measurement)
        let queue = MacroExecutionQueue(
            poster: poster,
            accessibility: permissions.currentAccessibility
        )
        let shortcuts = ShortcutCoordinator(carbon: carbon, hid: hid)
        let controller = AppController(
            store: store,
            shortcuts: shortcuts,
            permissions: permissions,
            queue: queue,
            measurementEnabled: measurementEnabled
        )

        measurement?.onProgress = { [weak controller] count in
            Task { @MainActor in
                controller?.updateMeasurementCount(count)
            }
        }
        controller.start()
        let settings = SettingsViewModel(
            settings: .init(macros: []),
            validator: validator
        )
        settings.loadDraftIfNeeded(from: controller)
        let login = LoginItemController(service: MainAppLoginService())

        self.controller = controller
        self.settings = settings
        self.login = login
        settings.onSave = { [weak self] value in
            self?.save(value)
        }
        // Cmd+Q 처럼 메뉴 바 종료 버튼을 거치지 않는 경로에서도 해제가 일어나야 한다.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated {
                controller?.shutdown()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func menuDidOpen() {
        login.refreshStatus()
        controller.refreshPermissions(
            forDraft: settings.settings,
            reconcileShortcuts: true
        )
        settings.synchronizeStatus(from: controller)
    }

    func settingsDidOpen() {
        controller.prepareSettingsDraft()
        settings.loadDraftIfNeeded(from: controller)
        settings.synchronizeStatus(from: controller)
    }

    func applicationDidBecomeActive() {
        login.refreshStatus()
        controller.refreshPermissions(
            forDraft: settings.settings,
            reconcileShortcuts: true
        )
        settings.synchronizeStatus(from: controller)
    }

    func menuActions(openSettings: @escaping () -> Void) -> AppMenuActions {
        AppMenuActions(
            openSettings: { [weak self] in
                self?.settingsDidOpen()
                openSettings()
            },
            openAbout: { NSApp.orderFrontStandardAboutPanel(nil) },
            terminate: { NSApp.terminate(nil) }
        )
    }

    private func save(_ value: AppSettings) {
        controller.draft = value
        controller.save()
        settings.synchronizeStatus(from: controller)
        if controller.saveError == nil {
            settings.markSaved(controller.draft)
        }
    }
}

@main
struct KocroApp: App {
    @StateObject private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        MenuBarExtra("Kocro", image: "MenuBarIcon") {
            Group {
                if #available(macOS 14.0, *) {
                    ModernMenuBarContent(dependencies: dependencies)
                } else {
                    MenuBarView(
                        app: dependencies.controller,
                        actions: dependencies.menuActions(
                            openSettings: LegacySettingsWindowAction.application.open
                        ),
                        refresh: dependencies.menuDidOpen
                    )
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    dependencies.applicationDidBecomeActive()
                }
            }
        }

        Settings {
            SettingsView(
                model: dependencies.settings,
                app: dependencies.controller,
                login: dependencies.login,
                prepare: dependencies.settingsDidOpen
            )
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    dependencies.applicationDidBecomeActive()
                }
            }
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private struct ModernMenuBarContent: View {
    @ObservedObject var dependencies: AppDependencies
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarView(
            app: dependencies.controller,
            actions: dependencies.menuActions(openSettings: openSettings.callAsFunction),
            refresh: dependencies.menuDidOpen
        )
    }
}
