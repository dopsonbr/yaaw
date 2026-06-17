import XCTest

@testable import YAAWKit

final class TerminalPreciseScrollAccumulatorTests: XCTestCase {
    func testAccumulatesTinyPreciseScrollDeltasUntilWholeUnit() {
        var accumulator = TerminalPreciseScrollAccumulator()

        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.35), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.35), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.35), .init(x: 0, y: -1))

        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.35), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.35), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.35), .init(x: 0, y: -1))
    }

    func testDirectionFlipDropsStaleRemainder() {
        var accumulator = TerminalPreciseScrollAccumulator()

        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: -0.6), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 0.5), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0, deltaY: 0.5), .init(x: 0, y: 1))
    }

    func testAxesAccumulateIndependently() {
        var accumulator = TerminalPreciseScrollAccumulator()

        XCTAssertEqual(accumulator.add(deltaX: 0.6, deltaY: -0.6), .zero)
        XCTAssertEqual(accumulator.add(deltaX: 0.6, deltaY: -0.6), .init(x: 1, y: -1))
        XCTAssertEqual(accumulator.add(deltaX: 0.8, deltaY: -0.8), .init(x: 1, y: -1))
    }
}

private extension TerminalPreciseScrollDelta {
    static let zero = TerminalPreciseScrollDelta(x: 0, y: 0)
}
