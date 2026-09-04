import XCTest
@testable import Kocro

final class KocroSmokeTests: XCTestCase {
    func testIdentity() {
        XCTAssertNotNil(KocroApp.self)
    }
}
