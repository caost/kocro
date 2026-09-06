import Foundation
import SwiftUI

enum OverallStatus: Equatable {
    case ready
    case accessibilityRequired
    case inputMonitoringRequired
    case settingsError
}

enum AppControllerError: Error {
    case shortcutCommitFailed
}

protocol ShortcutCoordinating: AnyObject {
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)? { get set }

    @MainActor
    func prepareReplacement(with settings: AppSettings) -> any ShortcutReplacementCandidate

    @MainActor
    func commit(
        _ candidate: any ShortcutReplacementCandidate,
        installSnapshots: ([UUID: RegistrationState]) -> Void
    ) -> [UUID: RegistrationState]?

    @MainActor
    func cancel(_ candidate: any ShortcutReplacementCandidate)

    @MainActor
    func shutdown()
}

protocol PermissionServing: AnyObject {
    var state: PermissionState { get }

    @discardableResult
    func refresh(needsHID: Bool) -> PermissionState
    func requestAccessibility()
    func requestInputMonitoring()
    func openSettings(_ kind: PrivacyKind)
    func currentAccessibility() -> Bool
}

protocol ExecutionQueueing: AnyObject {
    var lastResult: ExecutionResult? { get }
    var isIdle: Bool { get }
    var onResult: ((ExecutionResult) -> Void)? { get set }
    var onIdleChange: ((Bool) -> Void)? { get set }

    func enqueue(_ request: ExecutionRequest)
    func reject(id: UUID, shortcut: String, kind: ExecutionResultKind)
}

final class ExecutionSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: MacroDefinition] = [:]

    func replace(
        _ macros: [MacroDefinition],
        registration: [UUID: RegistrationState]
    ) {
        let registered = macros.filter {
            $0.isEnabled && registration[$0.id] == .registered
        }
        lock.lock()
        values = Dictionary(uniqueKeysWithValues: registered.map { ($0.id, $0) })
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }

    func request(
        _ id: UUID,
        receivedAt: ContinuousClock.Instant
    ) -> ExecutionRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard let macro = values[id], !macro.text.isEmpty else { return nil }
        return ExecutionRequest(
            id: id,
            shortcut: macro.shortcut.displayName,
            text: macro.text,
            trailing: macro.trailingKey,
            receivedAt: receivedAt
        )
    }
}

final class TriggerRouter: @unchecked Sendable {
    private let snapshots: ExecutionSnapshotStore
    private let queue: ExecutionQueueing
    private let accessibility: () -> Bool

    init(
        snapshots: ExecutionSnapshotStore,
        queue: ExecutionQueueing,
        accessibility: @escaping () -> Bool
    ) {
        self.snapshots = snapshots
        self.queue = queue
        self.accessibility = accessibility
    }

    func receive(id: UUID, receivedAt: ContinuousClock.Instant) {
        guard let request = snapshots.request(id, receivedAt: receivedAt) else {
            queue.reject(
                id: id,
                shortcut: "등록 ID \(id.uuidString)",
                kind: .missingDefinition
            )
            return
        }
        guard accessibility() else {
            queue.reject(
                id: id,
                shortcut: request.shortcut,
                kind: .accessibilityRequired
            )
            return
        }
        queue.enqueue(request)
    }
}

@MainActor
final class AppController: ObservableObject {
    @Published var draft = AppSettings(macros: [])
    @Published private(set) var runtime = AppSettings(macros: [])
    @Published private(set) var registration: [UUID: RegistrationState] = [:]
    @Published private(set) var lastResult: ExecutionResult?
    @Published private(set) var queueIsIdle: Bool
    @Published private(set) var measurementCount = 0
    @Published private(set) var loadError: Error?
    @Published private(set) var saveError: Error?
    @Published private(set) var showsReplaceWarning = false
    let measurementEnabled: Bool

    private let store: SettingsStoring
    private let shortcuts: ShortcutCoordinating
    private let permissions: PermissionServing
    private let queue: ExecutionQueueing
    private let snapshots: ExecutionSnapshotStore
    private let router: TriggerRouter
    private let validator = SettingsValidator()

    var overallStatus: OverallStatus {
        if loadError != nil { return .settingsError }
        if !permissions.state.accessibility { return .accessibilityRequired }
        if registration.values.contains(.inputMonitoringRequired) {
            return .inputMonitoringRequired
        }
        return .ready
    }

    var statusText: String {
        menuBar.statusText
    }

    var registeredCount: Int {
        menuBar.registeredCount
    }

    private var menuBar: MenuBarViewModel {
        MenuBarViewModel(
            statuses: [overallStatus],
            registrations: Array(registration.values)
        )
    }

    var permissionState: PermissionState {
        permissions.state
    }

    init(
        store: SettingsStoring,
        shortcuts: ShortcutCoordinating,
        permissions: PermissionServing,
        queue: ExecutionQueueing,
        measurementEnabled: Bool = false
    ) {
        let snapshots = ExecutionSnapshotStore()
        self.store = store
        self.shortcuts = shortcuts
        self.permissions = permissions
        self.queue = queue
        self.measurementEnabled = measurementEnabled
        self.snapshots = snapshots
        router = TriggerRouter(
            snapshots: snapshots,
            queue: queue,
            accessibility: permissions.currentAccessibility
        )
        lastResult = queue.lastResult
        queueIsIdle = queue.isIdle

        shortcuts.onTrigger = router.receive
        queue.onResult = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.lastResult = result
            }
        }
        queue.onIdleChange = { [weak self] idle in
            Task { @MainActor [weak self] in
                self?.queueIsIdle = idle
            }
        }
    }

    func start() {
        do {
            let value = try store.load()
            loadError = nil
            saveError = nil
            showsReplaceWarning = false
            refreshPermissions(for: value)
            guard installPersistedSettings(value, updateDraft: true) else {
                loadError = AppControllerError.shortcutCommitFailed
                return
            }
        } catch {
            runtime = .init(macros: [])
            draft = .init(macros: [])
            installPersistedSettings(.init(macros: []), updateDraft: false)
            loadError = error
            saveError = nil
            showsReplaceWarning = false
        }
    }

    func prepareSettingsDraft() {
        if loadError != nil, !showsReplaceWarning {
            draft = .defaults
            showsReplaceWarning = true
        }
        refreshPermissions()
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
    }

    func requestInputMonitoring() {
        permissions.requestInputMonitoring()
    }

    func openPrivacySettings(_ kind: PrivacyKind) {
        permissions.openSettings(kind)
    }

    func save() {
        let validated: AppSettings
        do {
            validated = try validator.validate(draft)
        } catch {
            saveError = error
            return
        }

        let candidate = shortcuts.prepareReplacement(with: validated)
        guard persist(candidate) else { return }
        guard commitReplacement(candidate, snapshotSettings: candidate.settings) else {
            saveError = AppControllerError.shortcutCommitFailed
            return
        }

        runtime = candidate.settings
        draft = candidate.settings
        loadError = nil
        saveError = nil
        showsReplaceWarning = false
        refreshPermissions(reconcileShortcuts: false)
    }

    func refreshPermissions(reconcileShortcuts: Bool = true) {
        refreshPermissions(for: runtime)
        if reconcileShortcuts {
            self.reconcileShortcuts()
        }
    }

    func updateMeasurementCount(_ count: Int) {
        measurementCount = count
    }

    func shutdown() {
        shortcuts.shutdown()
        snapshots.removeAll()
        registration = [:]
    }

    private func reconcileShortcuts() {
        let persisted = runtime
        let candidate = shortcuts.prepareReplacement(with: persisted)
        _ = commitReplacement(
            candidate,
            snapshotSettings: persisted,
            preservingRegistrationFailures: true
        )
    }

    private func refreshPermissions(for settings: AppSettings) {
        let needsHID = settings.macros.contains {
            $0.isEnabled && $0.shortcut.isHIDOnly
        }
        _ = permissions.refresh(needsHID: needsHID)
    }

    @discardableResult
    private func installPersistedSettings(
        _ settings: AppSettings,
        updateDraft: Bool
    ) -> Bool {
        let candidate = shortcuts.prepareReplacement(with: settings)
        guard commitReplacement(candidate, snapshotSettings: settings) else {
            return false
        }
        runtime = settings
        if updateDraft { draft = settings }
        return true
    }

    private func persist(_ candidate: any ShortcutReplacementCandidate) -> Bool {
        do {
            try store.save(candidate.settings)
            return true
        } catch {
            shortcuts.cancel(candidate)
            saveError = error
            return false
        }
    }

    private func commitReplacement(
        _ candidate: any ShortcutReplacementCandidate,
        snapshotSettings: AppSettings,
        preservingRegistrationFailures: Bool = false
    ) -> Bool {
        let retainedFailures = preservingRegistrationFailures
            ? registration.filter { id, state in
                state == .registrationFailed
                    && candidate.states[id] == nil
                    && snapshotSettings.macros.contains(where: { $0.id == id })
            }
            : [:]
        guard let committed = shortcuts.commit(candidate, installSnapshots: { [snapshots] states in
            snapshots.replace(snapshotSettings.macros, registration: states)
        }) else {
            return false
        }
        registration = committed.merging(retainedFailures) { current, _ in current }
        return true
    }
}
