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
    func unregister(id: UInt32)
    func unregisterAll()
}

protocol HIDServing: AnyObject {
    var hasPermission: Bool { get }
    var onFunction: ((UInt64, Int, ContinuousClock.Instant) -> Void)? { get set }
    func start(functions: Set<Int>) -> UInt64?
    func stop()
}

protocol ShortcutReplacementCandidate: AnyObject {
    var settings: AppSettings { get }
    var states: [UUID: RegistrationState] { get }
}

final class PreparedShortcutReplacement: ShortcutReplacementCandidate {
    let settings: AppSettings
    let states: [UUID: RegistrationState]
    fileprivate let transactionID: UUID
    fileprivate weak var owner: ShortcutCoordinator?

    fileprivate init(
        settings: AppSettings,
        states: [UUID: RegistrationState],
        transactionID: UUID,
        owner: ShortcutCoordinator
    ) {
        self.settings = settings
        self.states = states
        self.transactionID = transactionID
        self.owner = owner
    }

    deinit {
        guard let owner else { return }
        let transactionID = transactionID
        if Thread.isMainThread {
            owner.abandonPreparedReplacement(id: transactionID)
        } else {
            DispatchQueue.main.async { [weak owner] in
                owner?.abandonPreparedReplacement(id: transactionID)
            }
        }
    }
}

final class ShortcutCoordinator {
    private struct PendingReplacement {
        let transactionID: UUID
        let settings: AppSettings
        let states: [UUID: RegistrationState]
        let carbonRoutes: [UInt32: UUID]
        let carbonRegistrations: [ShortcutRegistrationIdentity: UInt32]
        let newlyRegisteredIDs: Set<UInt32>
        let hidFunctions: Set<Int>
    }

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
    private var carbonRegistrations: [ShortcutRegistrationIdentity: UInt32] = [:]
    private var currentHIDFunctions: Set<Int> = []
    private var currentHIDGeneration: UInt64?
    private var pendingReplacement: PendingReplacement?

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
        let candidate = prepareReplacement(with: AppSettings(macros: macros))
        return commit(candidate, installSnapshots: installSnapshots) ?? [:]
    }

    func prepareReplacement(
        with settings: AppSettings
    ) -> any ShortcutReplacementCandidate {
        // Carbon lifecycle APIs are main-thread-only. Callers must not invoke
        // replacement synchronously from onTrigger; schedule it on main instead.
        dispatchPrecondition(condition: .onQueue(.main))
        discardPendingReplacement()

        var candidateSettings = settings
        var states: [UUID: RegistrationState] = [:]
        var carbonIDs: [UInt32: UUID] = [:]
        var candidateRegistrations: [ShortcutRegistrationIdentity: UInt32] = [:]
        var newlyRegisteredIDs: Set<UInt32> = []

        for index in candidateSettings.macros.indices
        where candidateSettings.macros[index].isEnabled
            && !candidateSettings.macros[index].shortcut.isHIDOnly {
            let macro = candidateSettings.macros[index]
            guard let identity = macro.shortcut.registrationIdentity,
                  candidateRegistrations[identity] == nil else {
                states[macro.id] = .registrationFailed
                candidateSettings.macros[index].isEnabled = false
                continue
            }
            if let registrationID = carbonRegistrations[identity] {
                candidateRegistrations[identity] = registrationID
                carbonIDs[registrationID] = macro.id
                states[macro.id] = .registered
                continue
            }
            guard let registrationID = nextRegistrationID else {
                states[macro.id] = .registrationFailed
                candidateSettings.macros[index].isEnabled = false
                continue
            }
            let succeeded = carbon.register(
                id: registrationID,
                shortcut: macro.shortcut
            )
            states[macro.id] = succeeded ? .registered : .registrationFailed
            if succeeded {
                candidateRegistrations[identity] = registrationID
                carbonIDs[registrationID] = macro.id
                newlyRegisteredIDs.insert(registrationID)
            } else {
                candidateSettings.macros[index].isEnabled = false
            }
            nextRegistrationID = registrationID == UInt32.max
                ? nil
                : registrationID + 1
        }

        let hidMacros = candidateSettings.macros.filter {
            $0.isEnabled && $0.shortcut.isHIDOnly
        }
        let hidFunctions = Set(hidMacros.compactMap(\.shortcut.functionNumber))
        if !hidMacros.isEmpty {
            if !hid.hasPermission {
                hidMacros.forEach { states[$0.id] = .inputMonitoringRequired }
            } else {
                hidMacros.forEach { states[$0.id] = .registered }
            }
        }

        let transactionID = UUID()
        pendingReplacement = PendingReplacement(
            transactionID: transactionID,
            settings: candidateSettings,
            states: states,
            carbonRoutes: carbonIDs,
            carbonRegistrations: candidateRegistrations,
            newlyRegisteredIDs: newlyRegisteredIDs,
            hidFunctions: hidFunctions
        )
        return PreparedShortcutReplacement(
            settings: candidateSettings,
            states: states,
            transactionID: transactionID,
            owner: self
        )
    }

    @discardableResult
    func commit(
        _ candidate: any ShortcutReplacementCandidate,
        installSnapshots: ([UUID: RegistrationState]) -> Void = { _ in }
    ) -> [UUID: RegistrationState]? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let candidate = candidate as? PreparedShortcutReplacement,
              let pending = consume(candidate) else { return nil }
        ingress.beginReplacement()

        var states = pending.states
        let hidRoutes = installHID(
            functions: pending.hidFunctions,
            macros: pending.settings.macros,
            states: &states
        )
        installSnapshots(states)
        ingress.completeReplacement(
            carbonIDs: pending.carbonRoutes,
            hidFunctions: hidRoutes
        )

        installCarbonRegistrations(pending.carbonRegistrations)
        return states
    }

    func cancel(_ candidate: any ShortcutReplacementCandidate) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let candidate = candidate as? PreparedShortcutReplacement else { return }
        guard let pending = consume(candidate) else { return }
        pending.newlyRegisteredIDs.forEach { carbon.unregister(id: $0) }
    }

    func shutdown() {
        // See replace(with:installSnapshots:) for the lifecycle calling contract.
        dispatchPrecondition(condition: .onQueue(.main))
        ingress.beginReplacement()
        pendingReplacement = nil
        carbon.unregisterAll()
        hid.stop()
        carbonRegistrations.removeAll()
        currentHIDFunctions.removeAll()
        currentHIDGeneration = nil
        ingress.completeReplacement(carbonIDs: [:], hidFunctions: [:])
    }

    private func installHID(
        functions: Set<Int>,
        macros: [MacroDefinition],
        states: inout [UUID: RegistrationState]
    ) -> [HIDRoute: UUID] {
        let hidMacros = macros.filter { $0.isEnabled && $0.shortcut.isHIDOnly }
        guard !functions.isEmpty else {
            stopHIDIfActive()
            return [:]
        }

        guard hidMacros.allSatisfy({ states[$0.id] == .registered }) else {
            stopHIDIfActive()
            return [:]
        }

        if !currentHIDFunctions.isEmpty { hid.stop() }
        currentHIDGeneration = hid.start(functions: functions)
        currentHIDFunctions = currentHIDGeneration == nil ? [] : functions

        guard let generation = currentHIDGeneration else {
            for macro in hidMacros where states[macro.id] == .registered {
                states[macro.id] = .hidStartFailed
            }
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: hidMacros.compactMap { macro in
            macro.shortcut.functionNumber.map {
                (HIDRoute(generation: generation, function: $0), macro.id)
            }
        })
    }

    private func installCarbonRegistrations(
        _ registrations: [ShortcutRegistrationIdentity: UInt32]
    ) {
        let removedIDs = Set(carbonRegistrations.values)
            .subtracting(registrations.values)
        carbonRegistrations = registrations
        removedIDs.forEach { carbon.unregister(id: $0) }
    }

    private func stopHIDIfActive() {
        if !currentHIDFunctions.isEmpty { hid.stop() }
        currentHIDFunctions = []
        currentHIDGeneration = nil
    }

    fileprivate func abandonPreparedReplacement(id transactionID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pendingReplacement?.transactionID == transactionID else { return }
        discardPendingReplacement()
    }

    private func consume(
        _ candidate: PreparedShortcutReplacement
    ) -> PendingReplacement? {
        guard candidate.owner === self,
              pendingReplacement?.transactionID == candidate.transactionID else {
            return nil
        }
        let pending = pendingReplacement
        pendingReplacement = nil
        return pending
    }

    private func discardPendingReplacement() {
        guard let pending = pendingReplacement else { return }
        pendingReplacement = nil
        pending.newlyRegisteredIDs.forEach { carbon.unregister(id: $0) }
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
