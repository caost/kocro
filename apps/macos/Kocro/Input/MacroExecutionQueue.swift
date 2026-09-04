import Foundation

struct ExecutionRequest: Sendable {
    let id: UUID
    let shortcut: String
    let text: String
    let trailing: TrailingKey?
    let receivedAt: ContinuousClock.Instant
}

enum ExecutionResultKind: String, Equatable, Sendable {
    case postingRequested
    case accessibilityRequired
    case eventCreationFailed
    case missingDefinition
}

struct ExecutionResult: Equatable, Sendable, CustomStringConvertible {
    let id: UUID
    let shortcut: String
    let kind: ExecutionResultKind
    let date: Date

    var description: String {
        "\(id.uuidString.prefix(8)) \(shortcut) \(kind.rawValue) \(date.timeIntervalSince1970)"
    }
}

final class MacroExecutionQueue: @unchecked Sendable {
    private final class State {
        var pending = 0
        var isIdle = true
        var lastResult: ExecutionResult?
        var onResult: ((ExecutionResult) -> Void)?
        var onIdleChange: ((Bool) -> Void)?
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let executionQueue = DispatchQueue(label: "com.caost.Kocro.execution")
    private let stateQueue = DispatchQueue(label: "com.caost.Kocro.execution.state")
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private let poster: BatchPosting
    private let accessibility: () -> Bool
    private let state = State()

    init(poster: BatchPosting, accessibility: @escaping () -> Bool) {
        self.poster = poster
        self.accessibility = accessibility
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    var lastResult: ExecutionResult? {
        withState { $0.lastResult }
    }

    var isIdle: Bool {
        withState { $0.isIdle }
    }

    var onResult: ((ExecutionResult) -> Void)? {
        get { withState { $0.onResult } }
        set { withState { $0.onResult = newValue } }
    }

    var onIdleChange: ((Bool) -> Void)? {
        get { withState { $0.onIdleChange } }
        set { withState { $0.onIdleChange = newValue } }
    }

    func enqueue(_ request: ExecutionRequest) {
        let snapshot = ExecutionRequest(
            id: request.id,
            shortcut: request.shortcut,
            text: request.text,
            trailing: request.trailing,
            receivedAt: request.receivedAt
        )
        admit { [self] in
            let kind: ExecutionResultKind
            if !accessibility() {
                kind = .accessibilityRequired
            } else {
                do {
                    try poster.buildAndPost(snapshot)
                    kind = .postingRequested
                } catch {
                    kind = .eventCreationFailed
                }
            }
            return ExecutionResult(
                id: snapshot.id,
                shortcut: snapshot.shortcut,
                kind: kind,
                date: Date()
            )
        }
    }

    func reject(id: UUID, shortcut: String, kind: ExecutionResultKind) {
        admit {
            ExecutionResult(id: id, shortcut: shortcut, kind: kind, date: Date())
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            withState { state in
                guard state.pending > 0 else {
                    continuation.resume()
                    return
                }
                state.drainWaiters.append(continuation)
            }
        }
    }

    private func admit(_ operation: @escaping () -> ExecutionResult) {
        withState { state in
            let shouldAnnounceBusy = state.isIdle
            state.pending += 1
            state.isIdle = false

            executionQueue.async { [self] in
                finish(operation())
            }

            if shouldAnnounceBusy {
                state.onIdleChange?(false)
            }
        }
    }

    private func finish(_ result: ExecutionResult) {
        withState { state in
            state.lastResult = result
            state.pending -= 1
            state.onResult?(result)

            guard state.pending == 0 else { return }
            if !state.isIdle {
                state.isIdle = true
                state.onIdleChange?(true)
            }

            guard state.pending == 0 else { return }
            let waiters = state.drainWaiters
            state.drainWaiters.removeAll()
            waiters.forEach { continuation in
                continuation.resume()
            }
        }
    }

    @discardableResult
    private func withState<T>(_ body: (State) -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return body(state)
        }
        return stateQueue.sync {
            body(state)
        }
    }
}

extension MacroExecutionQueue: ExecutionQueueing {}
