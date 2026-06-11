import XCTest

@testable import YAAWKit

final class KitSmokeTests: XCTestCase {
    func testLibraryName() {
        XCTAssertEqual(YAAWKit.name, "YAAWKit")
    }
}
