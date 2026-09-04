import Foundation

enum RegistrationState: Equatable {
    case registered
    case registrationFailed
    case inputMonitoringRequired
    case hidStartFailed
}

protocol CarbonServing: AnyObject {
    var onRegistrationID: ((UInt32, ContinuousClock.Instant) -> Void)? { get set }
    func register(id: UInt32, shortcut: ShortcutDefinition) -> Bool
    func unregisterAll()
}

protocol HIDServing: AnyObject {
    var hasPermission: Bool { get }
    var onFunction: ((UInt64, Int, ContinuousClock.Instant) -> Void)? { get set }
    func start(functions: Set<Int>) -> UInt64?
    func stop()
}

final class ShortcutCoordinator {
    /// The handler must finish after taking its trigger-time snapshot and enqueueing work.
    /// Schedule lifecycle changes asynchronously on the main queue after the handler returns.
    var onTrigger: ((UUID, ContinuousClock.Instant) -> Void)? {
        get { ingress.trigger }
        set { ingress.trigger = newValue }
    }

    private let carbon: CarbonServing
    private let hid: HIDServing
    private let ingress = ShortcutIngress()
    private var nextRegistrationID: UInt32? = 1

    init(carbon: CarbonServing, hid: HIDServing) {
        self.carbon = carbon
        self.hid = hid

        carbon.onRegistrationID = { [weak self] registrationID, instant in
            self?.ingress.submitCarbon(id: registrationID, instant: instant)
        }
        hid.onFunction = { [weak self] generation, function, instant in
            self?.ingress.submitHID(
                generation: generation,
                function: function,
                instant: instant
            )
        }
    }

    func replace(
        with macros: [MacroDefinition],
        installSnapshots: ([UUID: RegistrationState]) -> Void = { _ in }
    ) -> [UUID: RegistrationState] {
        // Carbon lifecycle APIs are main-thread-only. Callers must not invoke
        // replacement synchronously from onTrigger; schedule it on main instead.
        dispatchPrecondition(condition: .onQueue(.main))
        ingress.beginReplacement()

        carbon.unregisterAll()
        hid.stop()

        let active = macros.filter(\.isEnabled)
        var states: [UUID: RegistrationState] = [:]
        var carbonIDs: [UInt32: UUID] = [:]
        var hidFunctions: [HIDRoute: UUID] = [:]

        for macro in active where !macro.shortcut.isHIDOnly {
            guard let registrationID = nextRegistrationID else {
                states[macro.id] = .registrationFailed
                continue
            }
            let succeeded = carbon.register(
                id: registrationID,
                shortcut: macro.shortcut
            )
            states[macro.id] = succeeded ? .registered : .registrationFailed
            if succeeded {
                carbonIDs[registrationID] = macro.id
            }
            nextRegistrationID = registrationID == UInt32.max
                ? nil
                : registrationID + 1
        }

        let hidMacros = active.filter(\.shortcut.isHIDOnly)
        if !hidMacros.isEmpty {
            if !hid.hasPermission {
                hidMacros.forEach { states[$0.id] = .inputMonitoringRequired }
            } else {
                let functions = Set(hidMacros.compactMap(\.shortcut.functionNumber))
                let generation = hid.start(functions: functions)
                if let generation {
                    for macro in hidMacros {
                        if let function = macro.shortcut.functionNumber {
                            let route = HIDRoute(
                                generation: generation,
                                function: function
                            )
                            hidFunctions[route] = macro.id
                        }
                    }
                }
                for macro in hidMacros {
                    states[macro.id] = generation != nil ? .registered : .hidStartFailed
                }
            }
        }

        installSnapshots(states)
        ingress.completeReplacement(carbonIDs: carbonIDs, hidFunctions: hidFunctions)
        return states
    }

    func shutdown() {
        // See replace(with:installSnapshots:) for the lifecycle calling contract.
        dispatchPrecondition(condition: .onQueue(.main))
        ingress.beginReplacement()
        carbon.unregisterAll()
        hid.stop()
        ingress.completeReplacement(carbonIDs: [:], hidFunctions: [:])
    }
}

extension ShortcutCoordinator: ShortcutCoordinating {}

private final class ShortcutIngress: @unchecked Sendable {
    private let condition = NSCondition()
    private let deliveryQueue = DispatchQueue(label: "com.caost.Kocro.shortcut-ingress")
    private var replacing = false
    private var carbonIDs: [UInt32: UUID] = [:]
    private var hidFunctions: [HIDRoute: UUID] = [:]
    private var triggerHandler: ((UUID, ContinuousClock.Instant) -> Void)?

    var trigger: ((UUID, ContinuousClock.Instant) -> Void)? {
        get { locked { triggerHandler } }
        set { locked { triggerHandler = newValue } }
    }

    func submitCarbon(id: UInt32, instant: ContinuousClock.Instant) {
        submit(instant: instant) { carbonIDs[id] }
    }

    func submitHID(
        generation: UInt64,
        function: Int,
        instant: ContinuousClock.Instant
    ) {
        submit(instant: instant) {
            hidFunctions[HIDRoute(generation: generation, function: function)]
        }
    }

    func beginReplacement() {
        condition.lock()
        replacing = true
        condition.unlock()
        deliveryQueue.sync {}
    }

    func completeReplacement(
        carbonIDs: [UInt32: UUID],
        hidFunctions: [HIDRoute: UUID]
    ) {
        condition.lock()
        self.carbonIDs = carbonIDs
        self.hidFunctions = hidFunctions
        replacing = false
        condition.broadcast()
        condition.unlock()
    }

    private func submit(
        instant: ContinuousClock.Instant,
        resolve: () -> UUID?
    ) {
        condition.lock()
        while replacing {
            condition.wait()
        }
        guard let macroID = resolve(), let triggerHandler else {
            condition.unlock()
            return
        }
        let delivered = DispatchSemaphore(value: 0)
        deliveryQueue.async {
            triggerHandler(macroID, instant)
            delivered.signal()
        }
        condition.unlock()
        delivered.wait()
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }
}

private struct HIDRoute: Hashable {
    let generation: UInt64
    let function: Int
}
