import AppKit
import ApplicationServices

struct PermissionState: Equatable {
    var accessibility: Bool
}

enum PrivacyKind: Equatable {
    case accessibility
}

protocol PermissionAPI: AnyObject {
    func accessibilityTrusted(prompt: Bool) -> Bool
    func currentAccessibilityTrusted() -> Bool
    func openSettings(_ kind: PrivacyKind)
}

final class PermissionClient {
    private let api: PermissionAPI
    private(set) var state = PermissionState(accessibility: false)

    init(api: PermissionAPI) {
        self.api = api
    }

    @discardableResult
    func refresh() -> PermissionState {
        state = PermissionState(
            accessibility: api.accessibilityTrusted(prompt: false)
        )
        return state
    }

    func requestAccessibility() {
        _ = api.accessibilityTrusted(prompt: true)
    }

    func openSettings(_ kind: PrivacyKind) {
        api.openSettings(kind)
    }

    func currentAccessibility() -> Bool {
        api.currentAccessibilityTrusted()
    }
}

extension PermissionClient: PermissionServing {}

final class SystemPermissionAPI: PermissionAPI {
    func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func currentAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func openSettings(_ kind: PrivacyKind) {
        NSWorkspace.shared.open(Self.settingsURL(for: kind))
    }

    static func settingsURL(for kind: PrivacyKind) -> URL {
        let value: String
        switch kind {
        case .accessibility:
            value = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        return URL(string: value)!
    }
}
