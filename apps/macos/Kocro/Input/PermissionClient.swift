import AppKit
import ApplicationServices
import IOKit.hidsystem

struct PermissionState: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool?
}

enum PrivacyKind: Equatable {
    case accessibility
    case inputMonitoring
}

protocol PermissionAPI: AnyObject {
    func accessibilityTrusted(prompt: Bool) -> Bool
    func inputMonitoringGranted() -> Bool
    func requestInputMonitoring()
    func openSettings(_ kind: PrivacyKind)
}

final class PermissionClient {
    private let api: PermissionAPI
    private(set) var state = PermissionState(accessibility: false, inputMonitoring: nil)

    init(api: PermissionAPI) {
        self.api = api
    }

    @discardableResult
    func refresh(needsHID: Bool) -> PermissionState {
        state = PermissionState(
            accessibility: api.accessibilityTrusted(prompt: false),
            inputMonitoring: needsHID ? api.inputMonitoringGranted() : nil
        )
        return state
    }

    func requestAccessibility() {
        _ = api.accessibilityTrusted(prompt: true)
    }

    func requestInputMonitoring() {
        api.requestInputMonitoring()
    }

    func openSettings(_ kind: PrivacyKind) {
        api.openSettings(kind)
    }
}

final class SystemPermissionAPI: PermissionAPI {
    func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func openSettings(_ kind: PrivacyKind) {
        NSWorkspace.shared.open(Self.settingsURL(for: kind))
    }

    static func settingsURL(for kind: PrivacyKind) -> URL {
        let value: String
        switch kind {
        case .accessibility:
            value = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            value = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }
        return URL(string: value)!
    }
}
