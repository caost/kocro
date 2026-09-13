import Carbon
import Foundation
import ServiceManagement
@testable import Kocro

final class MemorySettingsFile: SettingsFile {
    var contents: Data?
    var permissions: Int16?
    var replaceCount = 0
    var writeError: Error?

    init(contents: Data?) { self.contents = contents }
    var exists: Bool { contents != nil }

    func read() throws -> Data {
        guard let contents else { throw StoreError.io }
        return contents
    }

    func atomicReplace(with data: Data, permissions: Int16) throws {
        if let writeError { throw writeError }
        contents = data
        self.permissions = permissions
        replaceCount += 1
    }
}

enum Fixtures {
    static func macro(
        id: UUID = UUID(),
        title: String = "",
        text: String,
        shortcut: ShortcutDefinition = .init(key: .function(13), modifiers: [])
    ) -> MacroDefinition {
        .init(id: id, title: title, isEnabled: true, shortcut: shortcut,
              text: text, trailingKey: nil)
    }

    static func settings(text: String) -> AppSettings {
        .init(macros: [macro(text: text)])
    }

    static func carbon(_ number: Int) -> MacroDefinition {
        macro(text: "c\(number)", shortcut: .init(key: .function(number), modifiers: []))
    }
}

final class CarbonSpy: CarbonServing {
    var onRegistrationID: ((UInt32, ContinuousClock.Instant) -> Void)?
    var onUnregisterID: ((UInt32) -> Void)?
    var failingRegistration: Int?
    private(set) var registrations: [(id: UInt32, shortcut: ShortcutDefinition)] = []
    private(set) var unregisterAllCount = 0
    private(set) var unregisteredIDs: [UInt32] = []
    private(set) var lifecycleMainThreads: [Bool] = []

    init(failingRegistration: Int? = nil) { self.failingRegistration = failingRegistration }
    var registrationCount: Int { registrations.count }

    func register(id: UInt32, shortcut: ShortcutDefinition) -> RegistrationState {
        lifecycleMainThreads.append(Thread.isMainThread)
        registrations.append((id, shortcut))
        return registrations.count == failingRegistration ? .registrationFailed : .registered
    }

    func unregisterAll() {
        lifecycleMainThreads.append(Thread.isMainThread)
        unregisterAllCount += 1
    }

    func unregister(id: UInt32) {
        lifecycleMainThreads.append(Thread.isMainThread)
        unregisteredIDs.append(id)
        onUnregisterID?(id)
    }

    func send(id: UInt32) { onRegistrationID?(id, ContinuousClock.now) }
}

final class CarbonHotKeyAPISpy: CarbonHotKeyAPI {
    var registrationStatus: OSStatus = noErr
    var onUnregister: (() -> Void)?
    private(set) var options: [UInt32] = []
    private(set) var registeredIDs: [UInt32] = []
    private(set) var unregisteredReferences: [EventHotKeyRef] = []

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef,
        options: UInt32
    ) -> (OSStatus, EventHotKeyRef?) {
        self.options.append(options)
        registeredIDs.append(hotKeyID.id)
        let reference = registrationStatus == noErr
            ? EventHotKeyRef(bitPattern: Int(hotKeyID.id)) : nil
        return (registrationStatus, reference)
    }

    func unregister(_ hotKey: EventHotKeyRef) {
        unregisteredReferences.append(hotKey)
        onUnregister?()
    }
}

final class ObjectReleaseBox {
    var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
    func releaseValue() { value = nil }
}

final class PermissionAPISpy: PermissionAPI {
    var accessibility: Bool
    private(set) var accessibilityChecks: [Bool] = []
    private(set) var accessibilityPrompts = 0
    private(set) var currentAccessibilityChecks = 0
    private(set) var openedSettings: [PrivacyKind] = []

    init(accessibility: Bool) { self.accessibility = accessibility }

    func accessibilityTrusted(prompt: Bool) -> Bool {
        accessibilityChecks.append(prompt)
        if prompt { accessibilityPrompts += 1 }
        return accessibility
    }

    func currentAccessibilityTrusted() -> Bool {
        currentAccessibilityChecks += 1
        return accessibility
    }

    func openSettings(_ kind: PrivacyKind) { openedSettings.append(kind) }
}

final class EventAPISpy: EventAPI {
    typealias Event = Kocro.EventKind
    private let lock = NSLock()
    private var creationIndex = 0
    private var createdStorage: [Kocro.EventKind] = []
    private var postedStorage: [Kocro.EventKind] = []
    var failAt: Int?

    init(failAt: Int? = nil) { self.failAt = failAt }
    var created: [Kocro.EventKind] { locked { createdStorage } }
    var posted: [Kocro.EventKind] { locked { postedStorage } }

    func create(_ kind: Kocro.EventKind) -> Kocro.EventKind? {
        locked {
            creationIndex += 1
            createdStorage.append(kind)
            return creationIndex == failAt ? nil : kind
        }
    }

    func post(_ event: Kocro.EventKind) { locked { postedStorage.append(event) } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingBatchPoster: BatchPosting {
    private let lock = NSLock()
    private let error: Error?
    private var requestsStorage: [ExecutionRequest] = []
    private var currentConcurrent = 0
    private var maximumConcurrentStorage = 0

    init(error: Error? = nil) { self.error = error }
    var requests: [ExecutionRequest] { locked { requestsStorage } }
    var steps: [[MacroStep]] { requests.map(\.steps) }
    var texts: [String] {
        requests.map { request in
            request.steps.compactMap { step -> String? in
                guard case .text(let value) = step.kind else { return nil }
                return value
            }.joined()
        }
    }
    var maximumConcurrent: Int { locked { maximumConcurrentStorage } }

    func buildAndPost(_ request: ExecutionRequest) throws {
        locked {
            currentConcurrent += 1
            maximumConcurrentStorage = max(maximumConcurrentStorage, currentConcurrent)
            requestsStorage.append(request)
        }
        defer { locked { currentConcurrent -= 1 } }
        if let error { throw error }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class BlockingPoster: BatchPosting {
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var invocationCount = 0
    private var requestsStorage: [ExecutionRequest] = []
    private var currentConcurrent = 0
    private var maximumConcurrentStorage = 0

    var requests: [ExecutionRequest] { locked { requestsStorage } }
    var steps: [[MacroStep]] { requests.map(\.steps) }
    var texts: [String] {
        requests.map { request in
            request.steps.compactMap { step -> String? in
                guard case .text(let value) = step.kind else { return nil }
                return value
            }.joined()
        }
    }
    var maximumConcurrent: Int { locked { maximumConcurrentStorage } }

    func buildAndPost(_ request: ExecutionRequest) throws {
        let isFirst = locked {
            invocationCount += 1
            currentConcurrent += 1
            maximumConcurrentStorage = max(maximumConcurrentStorage, currentConcurrent)
            requestsStorage.append(request)
            return invocationCount == 1
        }
        defer { locked { currentConcurrent -= 1 } }
        if isFirst {
            firstEntered.signal()
            releaseFirst.wait()
        }
    }

    func waitUntilFirstRequestEnters() -> Bool {
        firstEntered.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstRequest() { releaseFirst.signal() }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class StoreSpy: SettingsStoring {
    var loadResult: Result<AppSettings, Error>
    var saveError: Error?
    var onSave: (() -> Void)?
    private var nextSaveError: Error?
    private(set) var savedValues: [AppSettings] = []

    init(loadResult: Result<AppSettings, Error>) { self.loadResult = loadResult }
    func load() throws -> AppSettings { try loadResult.get() }

    func save(_ value: AppSettings) throws {
        onSave?()
        if let nextSaveError {
            self.nextSaveError = nil
            throw nextSaveError
        }
        if let saveError { throw saveError }
        savedValues.append(value)
        loadResult = .success(value)
    }

    func failOnce(_ error: Error) { nextSaveError = error }
}

@MainActor
final class PipelineHarness {
    let store: StoreSpy
    let shortcuts = ShortcutSpy()
    let poster = RecordingBatchPoster()
    let queue: MacroExecutionQueue
    let app: AppController

    var postedSteps: [[MacroStep]] { poster.steps }
    var postedTexts: [String] { poster.texts }
    var maximumConcurrentPosts: Int { poster.maximumConcurrent }

    init(accessibility: Bool) {
        store = StoreSpy(loadResult: .success(.init(macros: [])))
        queue = MacroExecutionQueue(poster: poster, accessibility: { accessibility })
        app = AppController(
            store: store,
            shortcuts: shortcuts,
            permissions: PermissionSpy(
                state: .init(accessibility: accessibility),
                currentAccessibility: accessibility
            ),
            queue: queue
        )
    }

    func install(_ macros: [MacroDefinition]) {
        store.loadResult = .success(.init(macros: macros))
        app.start()
    }

    func trigger(_ id: UUID) { shortcuts.trigger(id) }
    func drain() async { await queue.drain() }

    func editText(_ text: String) {
        app.draft.macros[0] = app.draft.macros[0].withText(text)
    }

    func failNextSave() { store.failOnce(StoreError.io) }

    func saveAndTrigger() {
        app.save()
        shortcuts.trigger(app.runtime.macros[0].id)
    }
}

final class ShortcutSpy: ShortcutCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var statesStorage: [UUID: RegistrationState]
    private var triggerStorage: ((UUID, ContinuousClock.Instant) -> Void)?
    private var replaceCallsStorage: [[MacroDefinition]] = []
    var nextCandidateSettings: AppSettings?
    private(set) var prepareCalls: [AppSettings] = []
    private(set) var commitCount = 0
    private(set) var cancelCount = 0

    init(states: [UUID: RegistrationState] = [:]) { statesStorage = states }

    var states: [UUID: RegistrationState] {
        get { locked { statesStorage } }
        set { locked { statesStorage = newValue } }
    }
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)? {
        get { locked { triggerStorage } }
        set { locked { triggerStorage = newValue } }
    }
    var replaceCalls: [[MacroDefinition]] { locked { replaceCallsStorage } }

    func prepareReplacement(with settings: AppSettings) -> any ShortcutReplacementCandidate {
        prepareCalls.append(settings)
        let candidateSettings = nextCandidateSettings ?? settings
        replaceCallsStorage.append(settings.macros)
        let result = statesStorage.isEmpty
            ? Dictionary(uniqueKeysWithValues: candidateSettings.macros.filter(\.isEnabled).map {
                ($0.id, RegistrationState.registered)
            })
            : statesStorage
        return ShortcutCandidateSpy(settings: candidateSettings, states: result)
    }

    func commit(
        _ candidate: any ShortcutReplacementCandidate,
        installSnapshots: ([UUID: RegistrationState]) -> Void
    ) -> [UUID: RegistrationState]? {
        commitCount += 1
        installSnapshots(candidate.states)
        return candidate.states
    }

    func cancel(_ candidate: any ShortcutReplacementCandidate) { cancelCount += 1 }
    func shutdown() {}

    func trigger(_ id: UUID) {
        let trigger = locked { triggerStorage }
        trigger?(id, .now)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ShortcutCandidateSpy: ShortcutReplacementCandidate {
    let settings: AppSettings
    let states: [UUID: RegistrationState]

    init(settings: AppSettings, states: [UUID: RegistrationState]) {
        self.settings = settings
        self.states = states
    }
}

final class PermissionSpy: PermissionServing, @unchecked Sendable {
    private let lock = NSLock()
    private var stateStorage: PermissionState
    private var directAccessibility: Bool
    private var refreshedStateStorage: PermissionState?
    private var currentChecksStorage = 0

    init(
        state: PermissionState = .init(accessibility: true),
        currentAccessibility: Bool = true
    ) {
        stateStorage = state
        directAccessibility = currentAccessibility
    }

    var state: PermissionState { locked { stateStorage } }
    var refreshedState: PermissionState? {
        get { locked { refreshedStateStorage } }
        set { locked { refreshedStateStorage = newValue } }
    }
    var currentAccessibilityChecks: Int { locked { currentChecksStorage } }

    @discardableResult
    func refresh() -> PermissionState {
        locked {
            if let refreshedStateStorage { stateStorage = refreshedStateStorage }
            return stateStorage
        }
    }

    func requestAccessibility() {}
    func openSettings(_ kind: PrivacyKind) {}

    func currentAccessibility() -> Bool {
        locked {
            currentChecksStorage += 1
            return directAccessibility
        }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class QueueSpy: ExecutionQueueing, @unchecked Sendable {
    struct Rejection {
        let id: UUID
        let shortcut: String
        let kind: ExecutionResultKind
    }

    private let lock = NSLock()
    private var requestsStorage: [ExecutionRequest] = []
    private var rejectionsStorage: [Rejection] = []
    private var lastResultStorage: ExecutionResult?
    private var idleStorage = true
    private var resultHandler: ((ExecutionResult) -> Void)?
    private var idleHandler: ((Bool) -> Void)?

    var requests: [ExecutionRequest] { locked { requestsStorage } }
    var rejections: [Rejection] { locked { rejectionsStorage } }
    var lastResult: ExecutionResult? { locked { lastResultStorage } }
    var isIdle: Bool { locked { idleStorage } }
    var onResult: ((ExecutionResult) -> Void)? {
        get { locked { resultHandler } }
        set { locked { resultHandler = newValue } }
    }
    var onIdleChange: ((Bool) -> Void)? {
        get { locked { idleHandler } }
        set { locked { idleHandler = newValue } }
    }

    func enqueue(_ request: ExecutionRequest) { locked { requestsStorage.append(request) } }

    func reject(id: UUID, shortcut: String, kind: ExecutionResultKind) {
        locked { rejectionsStorage.append(.init(id: id, shortcut: shortcut, kind: kind)) }
    }

    func emitResult(_ result: ExecutionResult) {
        let handler = locked {
            lastResultStorage = result
            return resultHandler
        }
        handler?(result)
    }

    func emitIdle(_ idle: Bool) {
        let handler = locked {
            idleStorage = idle
            return idleHandler
        }
        handler?(idle)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
final class LoginServiceSpy: LoginService {
    enum Failure: Error { case denied }

    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterRegister: SMAppService.Status = .enabled
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
