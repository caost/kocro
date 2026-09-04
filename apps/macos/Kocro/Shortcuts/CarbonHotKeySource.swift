import Carbon
import Foundation

protocol CarbonHotKeyAPI: AnyObject {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef,
        options: UInt32
    ) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ hotKey: EventHotKeyRef)
}

final class CarbonHotKeySource: CarbonServing {
    var onRegistrationID: ((UInt32, ContinuousClock.Instant) -> Void)? {
        get { callbackContext.handler }
        set { callbackContext.handler = newValue }
    }

    private static let signature: OSType = 0x4B6F6372
    private let api: CarbonHotKeyAPI
    private let callbackContext = CarbonCallbackContext()
    private let resources: CarbonHotKeyResources

    init(api: CarbonHotKeyAPI = SystemCarbonHotKeyAPI()) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.api = api
        let contextPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                let instant = ContinuousClock.now
                guard let event, let context else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == CarbonHotKeySource.signature else { return status }
                let callbackContext = Unmanaged<CarbonCallbackContext>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                callbackContext.send(id: hotKeyID.id, instant: instant)
                return noErr
            },
            1,
            &eventType,
            contextPointer,
            &eventHandler
        )
        resources = CarbonHotKeyResources(
            api: api,
            eventHandler: eventHandler,
            callbackContext: contextPointer
        )
    }

    func register(id: UInt32, shortcut: ShortcutDefinition) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard resources.hasEventHandler,
              let keyCode = Self.keyCode(for: shortcut.key) else {
            return false
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let (status, hotKey) = api.register(
            keyCode: keyCode,
            modifiers: Self.carbonModifiers(shortcut.modifiers),
            hotKeyID: hotKeyID,
            target: GetApplicationEventTarget(),
            options: UInt32(kEventHotKeyExclusive)
        )
        guard status == noErr, let hotKey else { return false }
        resources.add(hotKey)
        return true
    }

    func unregisterAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        resources.unregisterAll()
    }

    deinit {
        callbackContext.handler = nil
        resources.dispose()
    }

    private static func carbonModifiers(_ modifiers: ModifierSet) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func keyCode(for key: ShortcutKey) -> UInt32? {
        switch key {
        case .empty:
            return nil
        case .keyCode(let code):
            return UInt32(code)
        case .letter(let letter):
            return MacKeyCodePolicy.keyCode(forLetter: letter).map(UInt32.init)
        case .function(let number):
            return MacKeyCodePolicy.keyCode(forFunction: number).map(UInt32.init)
        }
    }
}

private final class CarbonCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((UInt32, ContinuousClock.Instant) -> Void)?

    var handler: ((UInt32, ContinuousClock.Instant) -> Void)? {
        get { locked { callback } }
        set { locked { callback = newValue } }
    }

    func send(id: UInt32, instant: ContinuousClock.Instant) {
        let callback = locked { self.callback }
        callback?(id, instant)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CarbonHotKeyResources: @unchecked Sendable {
    private let api: CarbonHotKeyAPI
    private let disposalLock = NSLock()
    private var disposed = false
    private var eventHandler: EventHandlerRef?
    private var callbackContext: UnsafeMutableRawPointer?
    private var hotKeys: [EventHotKeyRef] = []

    init(
        api: CarbonHotKeyAPI,
        eventHandler: EventHandlerRef?,
        callbackContext: UnsafeMutableRawPointer
    ) {
        self.api = api
        self.eventHandler = eventHandler
        self.callbackContext = callbackContext
    }

    var hasEventHandler: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return eventHandler != nil
    }

    func add(_ hotKey: EventHotKeyRef) {
        dispatchPrecondition(condition: .onQueue(.main))
        hotKeys.append(hotKey)
    }

    func unregisterAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        hotKeys.forEach(api.unregister)
        hotKeys.removeAll()
    }

    func dispose() {
        disposalLock.lock()
        guard !disposed else {
            disposalLock.unlock()
            return
        }
        disposed = true
        disposalLock.unlock()

        if Thread.isMainThread {
            cleanupOnMain()
        } else {
            DispatchQueue.main.async { [self] in cleanupOnMain() }
        }
    }

    private func cleanupOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let callbackContext {
            Unmanaged<CarbonCallbackContext>.fromOpaque(callbackContext).release()
            self.callbackContext = nil
        }
    }
}

final class SystemCarbonHotKeyAPI: CarbonHotKeyAPI {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef,
        options: UInt32
    ) -> (OSStatus, EventHotKeyRef?) {
        dispatchPrecondition(condition: .onQueue(.main))
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            target,
            options,
            &hotKey
        )
        return (status, hotKey)
    }

    func unregister(_ hotKey: EventHotKeyRef) {
        dispatchPrecondition(condition: .onQueue(.main))
        UnregisterEventHotKey(hotKey)
    }
}
