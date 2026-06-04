import Foundation

/// Lossless backpressure between a PTY read loop (producer) and the terminal
/// output consumer (the ghostty write / capture pipeline).
///
/// The producer records bytes it has read with `produced(_:)` and parks in
/// `waitUntilReadable()` before each read; the consumer records bytes it has
/// delivered with `consumed(_:)`. When outstanding (produced-but-not-consumed)
/// bytes reach `highWaterMark`, the gate pauses the producer until they drain
/// back below `lowWaterMark` (hysteresis). While the producer is parked it is
/// not reading the PTY, so the kernel's PTY buffer fills and the child process's
/// writes block — backpressure with no dropped bytes.
public final class TerminalBackpressureGate: @unchecked Sendable {
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let condition = NSCondition()
    private var pendingBytes = 0
    private var paused = false
    private var closed = false

    public init(highWaterMark: Int = 1 * 1024 * 1024, lowWaterMark: Int = 256 * 1024) {
        precondition(highWaterMark > 0, "highWaterMark must be positive")
        precondition(
            lowWaterMark >= 0 && lowWaterMark < highWaterMark,
            "lowWaterMark must be in 0..<highWaterMark")
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
    }

    /// Producer: record bytes just read from the PTY. Call before handing the
    /// bytes downstream so a fast consumer can never `consumed` ahead of
    /// `produced` and drive the outstanding count negative.
    public func produced(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        condition.lock()
        pendingBytes += byteCount
        if pendingBytes >= highWaterMark {
            paused = true
        }
        condition.unlock()
    }

    /// Producer: block until reading is permitted again (or the gate closes).
    public func waitUntilReadable() {
        condition.lock()
        while paused && !closed {
            condition.wait()
        }
        condition.unlock()
    }

    /// Consumer: record bytes delivered downstream. Resumes the producer once
    /// the outstanding count falls back to `lowWaterMark`.
    public func consumed(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        condition.lock()
        pendingBytes = max(0, pendingBytes - byteCount)
        if paused && pendingBytes <= lowWaterMark {
            paused = false
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Permanently unblocks the producer (terminal closed / process exited).
    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    public var pendingByteCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return pendingBytes
    }

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused && !closed
    }
}
