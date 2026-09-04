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
}

struct EventBatchFactory<API: EventAPI> {
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

        if !current.isEmpty {
            output.append(current)
        }
        return output
    }

    func make(text: String, trailing: TrailingKey?) throws -> [API.Event] {
        let trailingKinds = try trailing.map(eventKinds(for:)) ?? []
        let kinds = chunks(text).map(EventKind.unicode) + trailingKinds
        var events: [API.Event] = []
        events.reserveCapacity(kinds.count)

        for kind in kinds {
            guard let event = api.create(kind) else {
                throw EventBuildError.creationFailed
            }
            events.append(event)
        }
        return events
    }

    private func eventKinds(for trailing: TrailingKey) throws -> [EventKind] {
        let keyCode: UInt16
        let modifiers: ModifierSet

        switch trailing {
        case .enter:
            keyCode = 36
            modifiers = []
        case .space:
            keyCode = 49
            modifiers = []
        case .tab:
            keyCode = 48
            modifiers = []
        case .custom(let value?, let flags):
            do {
                try SettingsValidator().validateTrailing(trailing)
            } catch {
                throw EventBuildError.invalidTrailingKey
            }
            keyCode = value
            modifiers = flags
        case .custom(nil, _), .customFunction:
            throw EventBuildError.invalidTrailingKey
        }

        return [.keyDown(keyCode, modifiers), .keyUp(keyCode, modifiers)]
    }
}

protocol BatchPosting: AnyObject {
    func buildAndPost(_ request: ExecutionRequest) throws
}

final class EventBatchPoster<API: EventAPI>: BatchPosting {
    private let api: API
    private let factory: EventBatchFactory<API>

    init(api: API, maximumUTF16Units: Int) {
        self.api = api
        factory = EventBatchFactory(api: api, maximumUTF16Units: maximumUTF16Units)
    }

    func buildAndPost(_ request: ExecutionRequest) throws {
        let events = try factory.make(text: request.text, trailing: request.trailing)
        events.forEach(api.post)
    }
}

final class CoreGraphicsBatchPoster: BatchPosting {
    static let maximumUTF16Units = 20

    private let poster: EventBatchPoster<SystemEventAPI>

    init(api: SystemEventAPI = SystemEventAPI()) {
        poster = EventBatchPoster(
            api: api,
            maximumUTF16Units: Self.maximumUTF16Units
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
            ) else {
                return nil
            }
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress!
                )
            }
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
        ) else {
            return nil
        }
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
