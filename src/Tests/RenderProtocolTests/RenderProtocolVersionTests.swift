import XCTest

@testable import YAAWRenderProtocol

final class RenderProtocolVersionTests: XCTestCase {
    func testCurrentVersionIsPositive() {
        XCTAssertGreaterThan(RenderProtocolVersion.current, 0)
    }
}
