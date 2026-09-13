import CoreGraphics
import Foundation

enum EventKind: Equatable, Sendable {
    case unicode(String)
    case keyDown(UInt16, ModifierSet)
    case keyUp(UInt16, ModifierSet)
}

protocol EventAPI: AnyObject {
    associatedtype Event
    func create(_ kind: EventKind) -> Event?
    func post(_ event: Event)
}

enum EventBuildError: Error, Equatable {
    case creationFailed
    case invalidTrailingKey
    case invalidDelay
}

struct EventBatchFactory<API: EventAPI> {
    struct EventSegment {
        let events: [API.Event]
        let delayAfterMilliseconds: Int
    }

    let api: API
    let maximumUTF16Units: Int

    init(api: API, maximumUTF16Units: Int) {
        precondition(maximumUTF16Units > 0)
        self.api = api
        self.maximumUTF16Units = maximumUTF16Units
    }

    func chunks(_ text: String) -> [String] {
        var output: [String] = []
        var current = ""
        for character in text {
            let characterText = String(character)
            if !current.isEmpty,
               current.utf16.count + characterText.utf16.count > maximumUTF16Units {
                output.append(current)
                current = characterText
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    func make(text: String, trailing: TrailingKey?) throws -> [API.Event] {
        try makeSegments(steps: MacroStep.legacySteps(text: text, trailingKey: trailing))
            .flatMap(\.events)
    }

    func makeSegments(steps: [MacroStep]) throws -> [EventSegment] {
        // Validate the complete sequence before allocating any events.
        for step in steps {
            switch step.kind {
            case .keys(let combination):
                guard combination.isValid else { throw EventBuildError.invalidTrailingKey }
            case .delay(let milliseconds):
                guard MacroStep.delayRange.contains(milliseconds) else {
                    throw EventBuildError.invalidDelay
                }
            case .text: break
            }
        }

        var segments: [EventSegment] = []
        var pendingDelay = 0
        for step in steps {
            let kinds: [EventKind]
            switch step.kind {
            case .text(let text):
                kinds = chunks(text).map(EventKind.unicode)
            case .keys(let combination):
                kinds = [
                    .keyDown(combination.keyCode, combination.modifiers),
                    .keyUp(combination.keyCode, combination.modifiers),
                ]
            case .delay(let milliseconds):
                // Leading delays have no preceding execution step.
                if !segments.isEmpty {
                    let sum = pendingDelay.addingReportingOverflow(milliseconds)
                    guard !sum.overflow else { throw EventBuildError.invalidDelay }
                    pendingDelay = sum.partialValue
                }
                continue
            }
            guard !kinds.isEmpty else { continue }
            var events: [API.Event] = []
            events.reserveCapacity(kinds.count)
            for kind in kinds {
                guard let event = api.create(kind) else {
                    throw EventBuildError.creationFailed
                }
                events.append(event)
            }
            if let previous = segments.last {
                segments[segments.count - 1] = EventSegment(
                    events: previous.events,
                    delayAfterMilliseconds: pendingDelay
                )
            }
            pendingDelay = 0
            segments.append(EventSegment(events: events, delayAfterMilliseconds: 0))
        }
        // A pending delay is used only when another emitting segment follows.
        return segments
    }
}

protocol BatchPosting: AnyObject {
    func buildAndPost(_ request: ExecutionRequest) throws
}

final class EventBatchPoster<API: EventAPI>: BatchPosting {
    private let api: API
    private let factory: EventBatchFactory<API>
    private let measurement: PostingMeasurementRecording?
    private let measurementFailure: (Error) -> Void
    private let sleep: (Int) -> Void

    init(
        api: API,
        maximumUTF16Units: Int,
        measurement: PostingMeasurementRecording? = nil,
        measurementFailure: @escaping (Error) -> Void = PostingMeasurementLog.record,
        sleep: @escaping (Int) -> Void = {
            Thread.sleep(forTimeInterval: Double($0) / 1_000)
        }
    ) {
        self.api = api
        factory = EventBatchFactory(api: api, maximumUTF16Units: maximumUTF16Units)
        self.measurement = measurement
        self.measurementFailure = measurementFailure
        self.sleep = sleep
    }

    func buildAndPost(_ request: ExecutionRequest) throws {
        let segments = try factory.makeSegments(steps: request.steps)
        for (index, segment) in segments.enumerated() {
            segment.events.forEach(api.post)
            if index + 1 < segments.count, segment.delayAfterMilliseconds > 0 {
                sleep(segment.delayAfterMilliseconds)
            }
        }
        do {
            try measurement?.record(receivedAt: request.receivedAt, postedAt: .now)
        } catch {
            measurementFailure(error)
        }
    }
}

final class CoreGraphicsBatchPoster: BatchPosting {
    static let maximumUTF16Units = 20
    private let poster: EventBatchPoster<SystemEventAPI>

    init(
        api: SystemEventAPI = SystemEventAPI(),
        measurement: PostingMeasurementRecording? = nil
    ) {
        poster = EventBatchPoster(
            api: api,
            maximumUTF16Units: Self.maximumUTF16Units,
            measurement: measurement
        )
    }

    func buildAndPost(_ request: ExecutionRequest) throws {
        try poster.buildAndPost(request)
    }
}

final class SystemEventAPI: EventAPI {
    func create(_ kind: EventKind) -> CGEvent? {
        switch kind {
        case .unicode(let text):
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            ) else { return nil }
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress!
                )
            }
            // 트리거 보조 키가 문자열을 단축키로 해석하게 하지 않도록 비운다.
            event.flags = []
            return event
        case .keyDown(let keyCode, let modifiers):
            return keyEvent(keyCode: keyCode, keyDown: true, modifiers: modifiers)
        case .keyUp(let keyCode, let modifiers):
            return keyEvent(keyCode: keyCode, keyDown: false, modifiers: modifiers)
        }
    }

    func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    private func keyEvent(
        keyCode: UInt16,
        keyDown: Bool,
        modifiers: ModifierSet
    ) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: keyDown
        ) else { return nil }
        event.flags = modifiers.cgEventFlags
        return event
    }
}

private extension ModifierSet {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}
