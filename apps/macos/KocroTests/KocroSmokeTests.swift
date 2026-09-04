import XCTest
@testable import Kocro

final class KocroSmokeTests: XCTestCase {
    func testIdentity() {
        XCTAssertNotNil(KocroApp.self)
    }

    func testAppDeclaresAppIcon() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
            "AppIcon"
        )
    }
}
