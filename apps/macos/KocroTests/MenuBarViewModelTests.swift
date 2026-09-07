import AppKit
import XCTest
@testable import Kocro

@MainActor
final class MenuBarViewModelTests: XCTestCase {
    func testInjectedAppMenuActionsInvokeEachClosureOnce() {
        var settingsOpenCount = 0
        var aboutCount = 0
        var terminateCount = 0
        let actions = AppMenuActions(
            openSettings: { settingsOpenCount += 1 },
            openAbout: { aboutCount += 1 },
            terminate: { terminateCount += 1 }
        )

        actions.openSettings()
        actions.openAbout()
        actions.terminate()

        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(aboutCount, 1)
        XCTAssertEqual(terminateCount, 1)
    }

    func testLegacySettingsWindowActionStopsAfterPreferencesSelectorSucceeds() {
        var selectors: [Selector] = []
        let action = LegacySettingsWindowAction { selector in
            selectors.append(selector)
            return true
        }

        action.open()

        XCTAssertEqual(selectors.map(NSStringFromSelector), ["showPreferencesWindow:"])
    }

    func testLegacySettingsWindowActionFallsBackToSettingsSelector() {
        var selectors: [Selector] = []
        let action = LegacySettingsWindowAction { selector in
            selectors.append(selector)
            return false
        }

        action.open()

        XCTAssertEqual(
            selectors.map(NSStringFromSelector),
            ["showPreferencesWindow:", "showSettingsWindow:"]
        )
    }

    func testStatusPriorityAndRegisteredCount() {
        let menu = MenuBarViewModel(
            statuses: [.accessibilityRequired, .settingsError],
            registrations: [.registered, .registrationFailed, .registered]
        )

        XCTAssertEqual(menu.statusText, "설정 오류")
        XCTAssertEqual(menu.registeredCount, 2)
        XCTAssertEqual(
            MenuBarViewModel(
                statuses: [.accessibilityRequired],
                registrations: []
            ).statusText,
            "Accessibility 권한 필요"
        )
    }

    func testRecentExecutionUsesUserTitleOrUUIDNeverMacroText() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "A1B2C3D4-1111-2222-3333-444444444444")
        )
        let result = ExecutionResult(
            id: id,
            shortcut: "F13",
            kind: .postingRequested,
            date: Date()
        )

        XCTAssertEqual(
            MenuBarViewModel.recentTitle(
                result: result,
                macros: [Fixtures.macro(id: id, title: "인사", text: "비밀")]
            ),
            "인사"
        )
        XCTAssertEqual(
            MenuBarViewModel.recentTitle(
                result: result,
                macros: [Fixtures.macro(id: id, title: "", text: "비밀")]
            ),
            "매크로 A1B2C3D4"
        )
    }

    func testNativeMenuDescriptorsHaveRequiredOrderAndOmitEmptyRecentRun() {
        XCTAssertEqual(
            MenuBarViewModel.menuItems(hasRecentResult: false),
            [.status, .settings, .about, .quit]
        )
        XCTAssertEqual(
            MenuBarViewModel.menuItems(hasRecentResult: true),
            [.status, .recentExecution, .settings, .about, .quit]
        )
    }

    func testRecentExecutionDetailUsesShortcutAndConcreteResult() {
        let id = UUID()
        let date = Date()

        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .postingRequested),
            "게시 요청 완료"
        )
        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .accessibilityRequired),
            "Accessibility 권한 필요"
        )
        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .eventCreationFailed),
            "이벤트 생성 실패"
        )
        XCTAssertEqual(
            MenuBarViewModel.resultText(for: .missingDefinition),
            "매크로 정의 없음"
        )
        XCTAssertEqual(
            MenuBarViewModel.recentDetail(
                result: ExecutionResult(
                    id: id,
                    shortcut: "⌘ A",
                    kind: .postingRequested,
                    date: date
                ),
                relativeDateText: "1분 전"
            ),
            "⌘ A · 게시 요청 완료 · 1분 전"
        )
    }

    func testAboutPanelContentUsesBundleMetadataAndAccessibleGitHubLink() {
        let content = AboutPanelContent(info: [
            "CFBundleDisplayName": "Kocro",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "NSHumanReadableCopyright": "Copyright © 2026 caost",
        ])

        XCTAssertEqual(content.applicationName, "Kocro")
        XCTAssertEqual(content.version, "1.0 (1)")
        XCTAssertEqual(content.copyright, "Copyright © 2026 caost")
        XCTAssertEqual(content.repositoryURL.absoluteString, "https://github.com/caost/kocro")
        XCTAssertEqual(content.credits.string, "GitHub")
        XCTAssertEqual(
            content.options[.copyright] as? String,
            "Copyright © 2026 caost"
        )
        XCTAssertEqual(
            content.credits.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            content.repositoryURL
        )
    }
}
