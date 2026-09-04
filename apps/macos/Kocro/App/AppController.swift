import Foundation
import SwiftUI

enum OverallStatus: Equatable {
    case ready
    case accessibilityRequired
    case inputMonitoringRequired
    case settingsError
}

protocol ShortcutCoordinating: AnyObject {
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)? { get set }

    @MainActor
    func replace(
        with macros: [MacroDefinition],
        installSnapshots: ([UUID: RegistrationState]) -> Void
    ) -> [UUID: RegistrationState]

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

    private let store: SettingsStoring
    private let shortcuts: ShortcutCoordinating
    private let permissions: PermissionServing
    private let queue: ExecutionQueueing
    private let snapshots: ExecutionSnapshotStore
    private let router: TriggerRouter

    var overallStatus: OverallStatus {
        if loadError != nil { return .settingsError }
        if !permissions.state.accessibility { return .accessibilityRequired }
        if registration.values.contains(.inputMonitoringRequired) {
            return .inputMonitoringRequired
        }
        return .ready
    }

    var statusText: String {
        MenuBarViewModel(statuses: [overallStatus], registrations: []).statusText
    }

    var permissionState: PermissionState {
        permissions.state
    }

    init(
        store: SettingsStoring,
        shortcuts: ShortcutCoordinating,
        permissions: PermissionServing,
        queue: ExecutionQueueing
    ) {
        let snapshots = ExecutionSnapshotStore()
        self.store = store
        self.shortcuts = shortcuts
        self.permissions = permissions
        self.queue = queue
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
            runtime = value
            draft = value
            loadError = nil
            saveError = nil
            showsReplaceWarning = false
            refreshPermissions(reconcileShortcuts: false)
            reconcileShortcuts()
        } catch {
            runtime = .init(macros: [])
            draft = .init(macros: [])
            registration = shortcuts.replace(with: []) { [snapshots] _ in
                snapshots.removeAll()
            }
            loadError = error
            saveError = nil
            showsReplaceWarning = false
        }
    }

    func openSettings() {
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

    func openSettings(_ kind: PrivacyKind) {
        permissions.openSettings(kind)
    }

    func save() {
        do {
            try store.save(draft)
            runtime = draft
            loadError = nil
            saveError = nil
            showsReplaceWarning = false
            refreshPermissions(reconcileShortcuts: false)
            reconcileShortcuts()
        } catch {
            saveError = error
        }
    }

    func refreshPermissions(reconcileShortcuts: Bool = true) {
        let needsHID = runtime.macros.contains {
            $0.isEnabled && $0.shortcut.isHIDOnly
        }
        _ = permissions.refresh(needsHID: needsHID)
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
        let macros = runtime.macros
        registration = shortcuts.replace(with: macros) { [snapshots] states in
            snapshots.replace(macros, registration: states)
        }
    }
}
