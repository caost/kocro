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
}
