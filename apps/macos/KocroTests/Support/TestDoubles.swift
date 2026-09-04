import Carbon
import Foundation
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
