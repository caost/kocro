import AppKit
import SwiftUI

extension NSApplication.AboutPanelOptionKey {
    static let copyright = Self(rawValue: "Copyright")
}

struct AboutPanelContent {
    let applicationName: String
    let version: String
    let copyright: String
    let repositoryURL = URL(string: "https://github.com/caost/kocro")!
    let credits: NSAttributedString

    init(bundle: Bundle = .main) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        applicationName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? "Kocro"

        let shortVersion = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        if shortVersion.isEmpty {
            version = build
        } else if build.isEmpty {
            version = shortVersion
        } else {
            version = "\(shortVersion) (\(build))"
        }

        copyright = info["NSHumanReadableCopyright"] as? String
            ?? "Copyright © 2026 caost"

        let credits = NSMutableAttributedString(string: "GitHub")
        credits.addAttribute(
            .link,
            value: repositoryURL,
            range: NSRange(location: 0, length: ("GitHub" as NSString).length)
        )
        self.credits = credits
    }

    var options: [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationName: applicationName,
            .applicationVersion: version,
            .credits: credits,
            .copyright: copyright,
        ]
    }
}

@MainActor
protocol ApplicationActivating: AnyObject {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activate()
}

@MainActor
private final class SystemApplicationActivation: ApplicationActivating {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        NSApp.setActivationPolicy(policy)
    }

    func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class SettingsWindowActivationController {
    private let application: ApplicationActivating
    private var isWindowOpen = false

    init(application: ApplicationActivating) {
        self.application = application
    }

    func windowDidOpen() {
        guard !isWindowOpen else { return }
        isWindowOpen = true
        guard application.setActivationPolicy(.regular) else { return }
        application.activate()
    }

    func windowDidClose() {
        guard isWindowOpen else { return }
        isWindowOpen = false
        _ = application.setActivationPolicy(.accessory)
    }
}

private struct SettingsWindowLifecycleObserver: NSViewRepresentable {
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> SettingsWindowObservationView {
        SettingsWindowObservationView(onOpen: onOpen, onClose: onClose)
    }

    func updateNSView(_ view: SettingsWindowObservationView, context: Context) {
        view.onOpen = onOpen
        view.onClose = onClose
    }
}

private final class SettingsWindowObservationView: NSView {
    var onOpen: () -> Void
    var onClose: () -> Void

    private weak var observedWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        stopObserving(notifyClose: observedWindow != nil)
        guard let window else { return }

        observedWindow = window
        onOpen()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopObserving(notifyClose: true)
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    private func stopObserving(notifyClose: Bool) {
        guard observedWindow != nil else { return }
        observedWindow = nil
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if notifyClose { onClose() }
    }
}

@MainActor
struct LegacySettingsWindowAction {
    let sendAction: (Selector) -> Bool

    init(sendAction: @escaping (Selector) -> Bool) {
        self.sendAction = sendAction
    }

    func open() {
        let didOpenPreferences = sendAction(Selector(("showPreferencesWindow:")))
        if !didOpenPreferences {
            _ = sendAction(Selector(("showSettingsWindow:")))
        }
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

    private let settingsWindowActivation = SettingsWindowActivationController(
        application: SystemApplicationActivation()
    )
    private var terminationObserver: NSObjectProtocol?

    init() {
        let validator = SettingsValidator()
        let store = JSONSettingsStore(
            file: ApplicationSupportSettingsFile(),
            validator: validator
        )
        let carbon = CarbonHotKeySource()
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
        let shortcuts = ShortcutCoordinator(carbon: carbon)
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
        controller.refreshPermissions(reconcileShortcuts: true)
        settings.synchronizeStatus(from: controller)
    }

    func settingsDidOpen() {
        controller.prepareSettingsDraft()
        settings.loadDraftIfNeeded(from: controller)
        settings.synchronizeStatus(from: controller)
    }

    func settingsWindowDidOpen() {
        settingsWindowActivation.windowDidOpen()
    }

    func settingsWindowDidClose() {
        settingsWindowActivation.windowDidClose()
    }

    func applicationDidBecomeActive() {
        login.refreshStatus()
        controller.refreshPermissions(reconcileShortcuts: true)
        settings.synchronizeStatus(from: controller)
    }

    func menuActions(openSettings: @escaping () -> Void) -> AppMenuActions {
        AppMenuActions(
            openSettings: { [weak self] in
                self?.settingsDidOpen()
                openSettings()
            },
            openAbout: {
                NSApp.orderFrontStandardAboutPanel(
                    options: AboutPanelContent().options
                )
            },
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
            .background(
                SettingsWindowLifecycleObserver(
                    onOpen: dependencies.settingsWindowDidOpen,
                    onClose: dependencies.settingsWindowDidClose
                )
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
