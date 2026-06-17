import Foundation

/// Preserves fractional precise-scroll deltas across the app/helper boundary.
///
/// The main app receives real trackpad deltas as `Double`s, but the render
/// helper currently has to rebuild an `NSEvent` for libghostty. AppKit truncates
/// tiny synthetic wheel deltas before libghostty sees them, so this accumulator
/// turns repeated fractional movement into whole pixel-wheel events while
/// retaining the remainder for the next gesture.
public struct TerminalPreciseScrollAccumulator: Sendable {
    private var remainderX: Double = 0
    private var remainderY: Double = 0

    public init() {}

    /// Adds a precise scroll delta and returns the whole units ready to dispatch.
    public mutating func add(deltaX: Double, deltaY: Double) -> TerminalPreciseScrollDelta {
        let wholeX = Self.add(deltaX, to: &remainderX)
        let wholeY = Self.add(deltaY, to: &remainderY)
        return TerminalPreciseScrollDelta(x: wholeX, y: wholeY)
    }

    private static func add(_ delta: Double, to remainder: inout Double) -> Int32 {
        guard delta.isFinite, delta != 0 else { return 0 }
        if remainder != 0, delta.sign != remainder.sign {
            remainder = 0
        }
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        guard whole != 0 else { return 0 }
        remainder -= whole
        if whole > Double(Int32.max) { return Int32.max }
        if whole < Double(Int32.min) { return Int32.min }
        return Int32(whole)
    }
}

public struct TerminalPreciseScrollDelta: Equatable, Sendable {
    public var x: Int32
    public var y: Int32

    public var isZero: Bool { x == 0 && y == 0 }
}
