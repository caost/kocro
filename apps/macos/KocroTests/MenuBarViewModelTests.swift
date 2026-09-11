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
            [.status, .macroList, .settings, .about, .quit]
        )
        XCTAssertEqual(
            MenuBarViewModel.menuItems(hasRecentResult: true),
            [.status, .macroList, .recentExecution, .settings, .about, .quit]
        )
    }

    func testExecutableMacrosExcludeDisabledUnregisteredAndEmptyTextInRuntimeOrder() {
        let first = Fixtures.macro(title: "첫 항목", text: "first secret")
        var disabled = Fixtures.macro(text: "disabled secret")
        disabled.isEnabled = false
        let failed = Fixtures.macro(text: "failed secret")
        let missing = Fixtures.macro(text: "missing secret")
        let empty = Fixtures.macro(text: "")
        let last = Fixtures.macro(title: "마지막 항목", text: " ")
        let items = MenuBarViewModel.executableMacros(
            macros: [first, disabled, failed, missing, empty, last],
            registration: [
                first.id: .registered,
                disabled.id: .registered,
                failed.id: .registrationFailed,
                empty.id: .registered,
                last.id: .registered,
            ]
        )

        XCTAssertEqual(items.map(\.id), [first.id, last.id])
        XCTAssertEqual(items.map(\.title), [first.title, last.title])
        XCTAssertNil(MenuBarViewModel.macroLayout(items: items).emptyMessage)
        let excluded = MenuBarViewModel.executableMacros(
            macros: [disabled, failed, missing, empty],
            registration: [disabled.id: .registered, empty.id: .registered]
        )
        XCTAssertTrue(excluded.isEmpty)
        XCTAssertEqual(
            MenuBarViewModel.macroLayout(items: excluded).emptyMessage,
            "실행 가능한 매크로 없음"
        )
    }

    func testMenuTitlesUseUUIDFallbackAndShortcutsUseDisplayName() throws {
        let id = try XCTUnwrap(UUID(uuidString: "A1B2C3D4-1111-2222-3333-444444444444"))
        let macros = [
            Fixtures.macro(id: id, text: "private body one"),
            Fixtures.macro(
                title: "인사",
                text: "private body two",
                shortcut: .init(key: .letter("a"), modifiers: [.command, .shift])
            ),
            Fixtures.macro(
                title: "이동",
                text: "private body three",
                shortcut: .init(key: .keyCode(48), modifiers: [.control, .option])
            ),
        ]
        let items = MenuBarViewModel.executableMacros(
            macros: macros,
            registration: Dictionary(uniqueKeysWithValues: macros.map { ($0.id, RegistrationState.registered) })
        )

        XCTAssertEqual(items.map(\.title), ["매크로 A1B2C3D4", "인사", "이동"])
        XCTAssertEqual(items.map(\.shortcut), macros.map { $0.shortcut.displayName })
        for item in items {
            XCTAssertEqual(item.displayName, "\(item.title) · \(item.shortcut)")
            for macro in macros {
                XCTAssertFalse(item.title.contains(macro.text))
                XCTAssertFalse(item.shortcut.contains(macro.text))
                XCTAssertFalse(item.displayName.contains(macro.text))
            }
        }
    }

    func testMacroLayoutKeepsFlatListThroughThreshold() {
        XCTAssertEqual(MenuBarViewModel.macroGroupSize, 10)
        for count in [0, 1, 9, 10] {
            let items = makeMenuItems(count: count)
            let layout = MenuBarViewModel.macroLayout(items: items)

            XCTAssertEqual(layout.items, items, "count: \(count)")
            XCTAssertTrue(layout.groups.isEmpty, "count: \(count)")
            XCTAssertEqual(layout.emptyMessage, count == 0 ? "실행 가능한 매크로 없음" : nil)
        }
    }

    func testMacroLayoutGroupsOverflowWithExactRangesAndNoMissingOrDuplicateItems() {
        let cases: [(count: Int, sizes: [Int], labels: [String])] = [
            (11, [1], ["매크로 11–11"]),
            (20, [10], ["매크로 11–20"]),
            (21, [10, 1], ["매크로 11–20", "매크로 21–21"]),
            (35, [10, 10, 5], ["매크로 11–20", "매크로 21–30", "매크로 31–35"]),
        ]
        for example in cases {
            let items = makeMenuItems(count: example.count)
            let layout = MenuBarViewModel.macroLayout(items: items)
            let flattened = layout.items + layout.groups.flatMap(\.items)

            XCTAssertEqual(layout.items, Array(items.prefix(10)))
            XCTAssertEqual(layout.groups.count, example.sizes.count)
            XCTAssertEqual(layout.groups.map { $0.items.count }, example.sizes)
            XCTAssertEqual(layout.groups.map(\.title), example.labels)
            XCTAssertEqual(Set(layout.groups.map(\.id)).count, layout.groups.count)
            XCTAssertEqual(flattened, items)
            XCTAssertEqual(Set(flattened.map(\.id)).count, example.count)
            XCTAssertNil(layout.emptyMessage)
        }
    }

    private func makeMenuItems(count: Int) -> [MenuMacroItem] {
        (0..<count).map {
            MenuMacroItem(id: UUID(), title: "항목 \($0 + 1)", shortcut: "F13")
        }
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
