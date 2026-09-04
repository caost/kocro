import Carbon
import Foundation
import ServiceManagement
@testable import Kocro

final class MemorySettingsFile: SettingsFile {
    var contents: Data?
    var permissions: Int16?
    var replaceCount = 0
    var writeError: Error?

    init(contents: Data?) {
        self.contents = contents
    }

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
        text: String,
        shortcut: ShortcutDefinition = .init(key: .function(13), modifiers: [])
    ) -> MacroDefinition {
        .init(id: id, isEnabled: true, shortcut: shortcut, text: text, trailingKey: nil)
    }

    static func settings(text: String) -> AppSettings {
        .init(macros: [macro(text: text)])
    }

    static func carbon(_ number: Int) -> MacroDefinition {
        macro(text: "c\(number)", shortcut: .init(key: .function(number), modifiers: []))
    }

    static func hid(_ number: Int) -> MacroDefinition {
        macro(text: "h\(number)", shortcut: .init(key: .function(number), modifiers: []))
    }

    static func enabledCarbonCarbonHID() -> [MacroDefinition] {
        [carbon(13), carbon(14), hid(21)]
    }
}

final class CarbonSpy: CarbonServing {
    var onRegistrationID: ((UInt32, ContinuousClock.Instant) -> Void)?
    var failingRegistration: Int?
    private(set) var registrations: [(id: UInt32, shortcut: ShortcutDefinition)] = []
    private(set) var unregisterAllCount = 0
    private(set) var lifecycleMainThreads: [Bool] = []

    init(failingRegistration: Int? = nil) {
        self.failingRegistration = failingRegistration
    }

    var registrationCount: Int { registrations.count }

    func register(id: UInt32, shortcut: ShortcutDefinition) -> Bool {
        lifecycleMainThreads.append(Thread.isMainThread)
        registrations.append((id, shortcut))
        return registrations.count != failingRegistration
    }

    func unregisterAll() {
        lifecycleMainThreads.append(Thread.isMainThread)
        unregisterAllCount += 1
    }

    func send(id: UInt32) {
        onRegistrationID?(id, ContinuousClock.now)
    }
}

final class CarbonHotKeyAPISpy: CarbonHotKeyAPI {
    var registrationStatus: OSStatus = noErr
    var onUnregister: (() -> Void)?
    private(set) var options: [UInt32] = []

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef,
        options: UInt32
    ) -> (OSStatus, EventHotKeyRef?) {
        self.options.append(options)
        let reference = registrationStatus == noErr ? EventHotKeyRef(bitPattern: 1) : nil
        return (registrationStatus, reference)
    }

    func unregister(_ hotKey: EventHotKeyRef) {
        onUnregister?()
    }
}

final class ObjectReleaseBox {
    var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }

    func releaseValue() {
        value = nil
    }
}

final class HIDSpy: HIDServing {
    var onFunction: ((UInt64, Int, ContinuousClock.Instant) -> Void)?
    var permission: Bool
    var starts: Bool
    private(set) var permissionChecks = 0
    private(set) var usages: Set<Int> = []
    private(set) var stopCount = 0
    private var nextGeneration: UInt64 = 1
    private var activeGeneration: UInt64?

    init(permission: Bool, starts: Bool) {
        self.permission = permission
        self.starts = starts
    }

    var hasPermission: Bool {
        permissionChecks += 1
        return permission
    }

    func start(functions: Set<Int>) -> UInt64? {
        usages = functions
        let generation = nextGeneration
        nextGeneration += 1
        activeGeneration = starts ? generation : nil
        return activeGeneration
    }

    func stop() {
        activeGeneration = nil
        stopCount += 1
    }

    func send(function: Int) {
        guard let activeGeneration else { return }
        onFunction?(activeGeneration, function, ContinuousClock.now)
    }
}

final class HIDAPISpy: HIDAPI {
    private(set) var matchingUsages: Set<Int> = []
    var opens = true
    private let lock = NSLock()
    private var callbacks: [(Int, Int, ContinuousClock.Instant) -> Void] = []

    func start(
        matching usages: Set<Int>,
        onValue: @escaping (Int, Int, ContinuousClock.Instant) -> Void
    ) -> Bool {
        lock.lock()
        matchingUsages = usages
        callbacks.append(onValue)
        lock.unlock()
        return opens
    }

    func stop() {}

    func send(usage: Int, value: Int) {
        send(
            session: callbacks.count - 1,
            usage: usage,
            value: value,
            instant: ContinuousClock.now
        )
    }

    func send(
        session: Int,
        usage: Int,
        value: Int,
        instant: ContinuousClock.Instant
    ) {
        lock.lock()
        let callback = callbacks[session]
        lock.unlock()
        callback(usage, value, instant)
    }
}

final class TriggerSpy {
    private(set) var functions: [Int] = []
    private(set) var instants: [ContinuousClock.Instant] = []

    func call(_ function: Int, _ instant: ContinuousClock.Instant) {
        functions.append(function)
        instants.append(instant)
    }
}

final class PermissionAPISpy: PermissionAPI {
    var accessibility: Bool
    var input: Bool
    private(set) var accessibilityChecks: [Bool] = []
    private(set) var accessibilityPrompts = 0
    private(set) var currentAccessibilityChecks = 0
    private(set) var inputChecks = 0
    private(set) var inputRequests = 0
    private(set) var openedSettings: [PrivacyKind] = []

    init(accessibility: Bool, input: Bool) {
        self.accessibility = accessibility
        self.input = input
    }

    func accessibilityTrusted(prompt: Bool) -> Bool {
        accessibilityChecks.append(prompt)
        if prompt { accessibilityPrompts += 1 }
        return accessibility
    }

    func currentAccessibilityTrusted() -> Bool {
        currentAccessibilityChecks += 1
        return accessibility
    }

    func inputMonitoringGranted() -> Bool {
        inputChecks += 1
        return input
    }

    func requestInputMonitoring() {
        inputRequests += 1
    }

    func openSettings(_ kind: PrivacyKind) {
        openedSettings.append(kind)
    }
}

final class EventAPISpy: EventAPI {
    typealias Event = Kocro.EventKind

    private let lock = NSLock()
    private var creationIndex = 0
    private var createdStorage: [Kocro.EventKind] = []
    private var postedStorage: [Kocro.EventKind] = []
    var failAt: Int?

    init(failAt: Int? = nil) {
        self.failAt = failAt
    }

    var created: [Kocro.EventKind] { locked { createdStorage } }
    var posted: [Kocro.EventKind] { locked { postedStorage } }

    func create(_ kind: Kocro.EventKind) -> Kocro.EventKind? {
        locked {
            creationIndex += 1
            createdStorage.append(kind)
            return creationIndex == failAt ? nil : kind
        }
    }

    func post(_ event: Kocro.EventKind) {
        locked { postedStorage.append(event) }
    }

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

    init(error: Error? = nil) {
        self.error = error
    }

    var requests: [ExecutionRequest] { locked { requestsStorage } }
    var texts: [String] { requests.map(\.text) }
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
    private var textsStorage: [String] = []
    private var currentConcurrent = 0
    private var maximumConcurrentStorage = 0

    var texts: [String] { locked { textsStorage } }
    var maximumConcurrent: Int { locked { maximumConcurrentStorage } }

    func buildAndPost(_ request: ExecutionRequest) throws {
        let isFirst = locked {
            invocationCount += 1
            currentConcurrent += 1
            maximumConcurrentStorage = max(maximumConcurrentStorage, currentConcurrent)
            textsStorage.append(request.text)
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

    func releaseFirstRequest() {
        releaseFirst.signal()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class StoreSpy: SettingsStoring {
    let loadResult: Result<AppSettings, Error>
    var saveError: Error?
    var onSave: (() -> Void)?
    private(set) var savedValues: [AppSettings] = []

    init(loadResult: Result<AppSettings, Error>) {
        self.loadResult = loadResult
    }

    func load() throws -> AppSettings {
        try loadResult.get()
    }

    func save(_ value: AppSettings) throws {
        onSave?()
        if let saveError { throw saveError }
        savedValues.append(value)
    }
}

final class ShortcutSpy: ShortcutCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var statesStorage: [UUID: RegistrationState]
    private var triggerStorage: ((UUID, ContinuousClock.Instant) -> Void)?
    private var replaceCallsStorage: [[MacroDefinition]] = []

    init(states: [UUID: RegistrationState] = [:]) {
        statesStorage = states
    }

    var states: [UUID: RegistrationState] {
        get { locked { statesStorage } }
        set { locked { statesStorage = newValue } }
    }
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)? {
        get { locked { triggerStorage } }
        set { locked { triggerStorage = newValue } }
    }
    var replaceCalls: [[MacroDefinition]] { locked { replaceCallsStorage } }

    func replace(
        with macros: [MacroDefinition],
        installSnapshots: ([UUID: RegistrationState]) -> Void
    ) -> [UUID: RegistrationState] {
        let result = locked {
            replaceCallsStorage.append(macros)
            if statesStorage.isEmpty {
                return Dictionary(
                    uniqueKeysWithValues: macros.filter(\.isEnabled).map {
                        ($0.id, RegistrationState.registered)
                    }
                )
            }
            return statesStorage
        }
        installSnapshots(result)
        return result
    }

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

final class PermissionSpy: PermissionServing, @unchecked Sendable {
    private let lock = NSLock()
    private var stateStorage: PermissionState
    private var directAccessibility: Bool
    private var refreshedStateStorage: PermissionState?
    private var refreshNeedsHIDStorage: [Bool] = []
    private var currentChecksStorage = 0

    init(
        state: PermissionState = .init(accessibility: true, inputMonitoring: nil),
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
    var refreshNeedsHID: [Bool] { locked { refreshNeedsHIDStorage } }
    var currentAccessibilityChecks: Int { locked { currentChecksStorage } }

    @discardableResult
    func refresh(needsHID: Bool) -> PermissionState {
        locked {
            refreshNeedsHIDStorage.append(needsHID)
            if let refreshedStateStorage { stateStorage = refreshedStateStorage }
            return stateStorage
        }
    }

    func requestAccessibility() {}
    func requestInputMonitoring() {}
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

    func enqueue(_ request: ExecutionRequest) {
        locked { requestsStorage.append(request) }
    }

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

    init(status: SMAppService.Status) {
        self.status = status
    }

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
