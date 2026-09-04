import AppKit
import SwiftUI

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
        controller.refreshPermissions()
        settings.synchronizeStatus(from: controller)
    }

    func settingsDidOpen() {
        controller.prepareSettingsDraft()
        settings.loadDraftIfNeeded(from: controller)
        settings.synchronizeStatus(from: controller)
    }

    func applicationDidBecomeActive() {
        login.refreshStatus()
        controller.refreshPermissions()
        settings.synchronizeStatus(from: controller)
    }

    func openSettingsWindow() {
        settingsDidOpen()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
        MenuBarExtra("Kocro", systemImage: "keyboard") {
            MenuBarView(
                app: dependencies.controller,
                login: dependencies.login,
                openSettingsWindow: dependencies.openSettingsWindow,
                refresh: dependencies.menuDidOpen
            )
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    dependencies.applicationDidBecomeActive()
                }
            }
        }

        Settings {
            SettingsView(
                model: dependencies.settings,
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
