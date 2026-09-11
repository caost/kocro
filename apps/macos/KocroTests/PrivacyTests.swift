import XCTest
@testable import Kocro

final class PrivacyTests: XCTestCase {
    func testResultDescriptionHasNoMacroTextOrTargetApplication() {
        let value = ExecutionResult(
            id: UUID(),
            shortcut: "F13",
            kind: .postingRequested,
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertFalse(value.description.contains("secret"))
        XCTAssertFalse(value.description.contains("TextEdit"))
        XCTAssertEqual(value.description.components(separatedBy: " ").count, 4)
    }

    func testFlatAndGroupedMenuDisplayStringsNeverExposeMacroBodies() {
        let macros = (0..<23).map { index in
            Fixtures.macro(
                title: index.isMultiple(of: 2) ? "" : "제목 \(index)",
                text: "PRIVATE-MACRO-BODY-\(index)-END"
            )
        }
        let registration = Dictionary(uniqueKeysWithValues: macros.map {
            ($0.id, RegistrationState.registered)
        })
        let layout = MenuBarViewModel.macroLayout(
            items: MenuBarViewModel.executableMacros(macros: macros, registration: registration)
        )
        let items = layout.items + layout.groups.flatMap(\.items)
        let strings = items.flatMap { [$0.title, $0.shortcut, $0.displayName] }
            + layout.groups.map(\.title)
            + [layout.emptyMessage ?? ""]

        XCTAssertEqual(items.count, macros.count)
        XCTAssertFalse(layout.groups.isEmpty)
        for macro in macros {
            for string in strings {
                XCTAssertFalse(string.contains(macro.text))
            }
        }
    }
}
