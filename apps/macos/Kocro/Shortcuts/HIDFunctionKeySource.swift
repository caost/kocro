import Foundation
import IOKit.hid
import IOKit.hidsystem

protocol HIDAPI: AnyObject {
    func start(
        matching usages: Set<Int>,
        onValue: @escaping (Int, Int, ContinuousClock.Instant) -> Void
    ) -> Bool
    func stop()
}

final class HIDFunctionKeySource: HIDServing {
    var onFunction: ((UInt64, Int, ContinuousClock.Instant) -> Void)? {
        get { locked { trigger } }
        set { locked { trigger = newValue } }
    }

    var hasPermission: Bool {
        permissionCheck()
    }

    private let api: HIDAPI
    private let beforeEmit: () -> Void
    private let permissionCheck: () -> Bool
    private let stateLock = NSLock()
    private var trigger: ((UInt64, Int, ContinuousClock.Instant) -> Void)?
    private var activeSession: Session?
    private var nextGeneration: UInt64? = 1
    private var requestedUsages: Set<Int> = []
    private var pressedUsages: Set<Int> = []

    init(
        api: HIDAPI = IOKitHIDAPI(),
        beforeEmit: @escaping () -> Void = {},
        permissionCheck: @escaping () -> Bool = {
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    ) {
        self.api = api
        self.beforeEmit = beforeEmit
        self.permissionCheck = permissionCheck
    }

    static func matchingUsages(_ functions: Set<Int>) -> Set<Int> {
        Set(functions.compactMap { function in
            guard (21...24).contains(function) else { return nil }
            return 0x70 + function - 21
        })
    }

    func start(functions: Set<Int>) -> UInt64? {
        let usages = Self.matchingUsages(functions)
        guard let session = locked({ () -> Session? in
            guard let generation = nextGeneration else { return nil }
            nextGeneration = generation == UInt64.max ? nil : generation + 1
            let session = Session(generation: generation)
            activeSession = session
            requestedUsages = usages
            pressedUsages.removeAll()
            return session
        }) else { return nil }
        let started = api.start(matching: usages) { [weak self] usage, value, instant in
            self?.receive(
                usage: usage,
                value: value,
                instant: instant,
                session: session
            )
        }
        if !started {
            locked {
                guard activeSession === session else { return }
                activeSession = nil
                requestedUsages.removeAll()
                pressedUsages.removeAll()
            }
        }
        return started ? session.generation : nil
    }

    func stop() {
        locked {
            activeSession = nil
            requestedUsages.removeAll()
            pressedUsages.removeAll()
        }
        api.stop()
    }

    private func receive(
        usage: Int,
        value: Int,
        instant: ContinuousClock.Instant,
        session: Session
    ) {
        let action: (() -> Void)? = locked {
            guard activeSession === session, requestedUsages.contains(usage) else { return nil }
            if value == 0 {
                pressedUsages.remove(usage)
                return nil
            }
            guard value > 0, pressedUsages.insert(usage).inserted,
                  let trigger else { return nil }
            let function = usage - 0x70 + 21
            return { trigger(session.generation, function, instant) }
        }
        guard let action else { return }
        beforeEmit()
        guard permissionCheck() else { return }
        action()
    }

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private final class Session {
        let generation: UInt64

        init(generation: UInt64) {
            self.generation = generation
        }
    }
}

final class IOKitHIDAPI: HIDAPI {
    private let lifecycleQueue = DispatchQueue(label: "com.caost.Kocro.hid-api")
    private let deliveryQueue = DispatchQueue(label: "com.caost.Kocro.hid-api-delivery")
    private let lifecycleQueueKey = DispatchSpecificKey<Void>()
    private var manager: IOHIDManager?
    private var onValue: ((Int, Int, ContinuousClock.Instant) -> Void)?
    private var activeSessionID: UUID?

    init() {
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: ())
    }

    func start(
        matching usages: Set<Int>,
        onValue: @escaping (Int, Int, ContinuousClock.Instant) -> Void
    ) -> Bool {
        withLifecycle {
            stopOnQueue()
            guard !usages.isEmpty else { return false }

            let manager = IOHIDManagerCreate(
                kCFAllocatorDefault,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            let sessionID = UUID()
            let context = Unmanaged.passRetained(
                CallbackContext(api: self, sessionID: sessionID)
            ).toOpaque()
            let matches = usages.map { usage -> [String: Int] in
                [
                    kIOHIDElementUsagePageKey: Int(kHIDPage_KeyboardOrKeypad),
                    kIOHIDElementUsageKey: usage,
                ]
            }
            IOHIDManagerSetInputValueMatchingMultiple(manager, matches as CFArray)
            IOHIDManagerRegisterInputValueCallback(
                manager,
                { context, _, _, value in
                    let instant = ContinuousClock.now
                    guard let context else { return }
                    let callbackContext = Unmanaged<CallbackContext>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    let element = IOHIDValueGetElement(value)
                    callbackContext.api?.deliver(
                        sessionID: callbackContext.sessionID,
                        usage: Int(IOHIDElementGetUsage(element)),
                        value: IOHIDValueGetIntegerValue(value),
                        instant: instant
                    )
                },
                context
            )

            guard IOHIDManagerOpen(
                manager,
                IOOptionBits(kIOHIDOptionsTypeNone)
            ) == kIOReturnSuccess else {
                Unmanaged<CallbackContext>.fromOpaque(context).release()
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                return false
            }

            IOHIDManagerSetDispatchQueue(manager, lifecycleQueue)
            IOHIDManagerSetCancelHandler(manager) {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                Unmanaged<CallbackContext>.fromOpaque(context).release()
            }
            self.manager = manager
            self.onValue = onValue
            activeSessionID = sessionID
            IOHIDManagerActivate(manager)
            return true
        }
    }

    func stop() {
        withLifecycle { stopOnQueue() }
    }

    private func stopOnQueue() {
        guard let manager else { return }
        activeSessionID = nil
        onValue = nil
        self.manager = nil
        IOHIDManagerCancel(manager)
    }

    private func deliver(
        sessionID: UUID,
        usage: Int,
        value: Int,
        instant: ContinuousClock.Instant
    ) {
        guard activeSessionID == sessionID else { return }
        guard let onValue else { return }
        deliveryQueue.async {
            onValue(usage, value, instant)
        }
    }

    private func withLifecycle<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return body()
        }
        return lifecycleQueue.sync(execute: body)
    }

    deinit {
        stop()
    }

    private final class CallbackContext {
        weak var api: IOKitHIDAPI?
        let sessionID: UUID

        init(api: IOKitHIDAPI, sessionID: UUID) {
            self.api = api
            self.sessionID = sessionID
        }
    }
}
