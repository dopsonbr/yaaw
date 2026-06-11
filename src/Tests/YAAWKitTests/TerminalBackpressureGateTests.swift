import XCTest

@testable import YAAWKit

final class TerminalBackpressureGateTests: XCTestCase {
    func testPausesAtHighWaterAndResumesAtLowWater() {
        let gate = TerminalBackpressureGate(highWaterMark: 1000, lowWaterMark: 250)

        gate.produced(500)
        XCTAssertFalse(gate.isPaused)

        gate.produced(600)  // 1100 >= 1000 high-water
        XCTAssertTrue(gate.isPaused)
        XCTAssertEqual(gate.pendingByteCount, 1100)

        // Draining between low and high keeps it paused (hysteresis).
        gate.consumed(400)  // 700, still > 250
        XCTAssertTrue(gate.isPaused)

        gate.consumed(500)  // 200 <= 250 low-water
        XCTAssertFalse(gate.isPaused)
        XCTAssertEqual(gate.pendingByteCount, 200)
    }

    func testWaitUntilReadableBlocksWhilePausedAndUnblocksOnDrain() {
        let gate = TerminalBackpressureGate(highWaterMark: 100, lowWaterMark: 10)
        gate.produced(100)
        XCTAssertTrue(gate.isPaused)

        let resumed = expectation(description: "producer resumed")
        let lock = NSLock()
        var hasResumed = false
        DispatchQueue.global().async {
            gate.waitUntilReadable()  // should block until drained
            lock.lock()
            hasResumed = true
            lock.unlock()
            resumed.fulfill()
        }

        // Still blocked after a beat.
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        XCTAssertFalse(hasResumed)
        lock.unlock()

        gate.consumed(95)  // 5 <= 10 low-water → resume
        wait(for: [resumed], timeout: 1.0)
    }

    func testCloseUnblocksParkedProducer() {
        let gate = TerminalBackpressureGate(highWaterMark: 100, lowWaterMark: 10)
        gate.produced(200)
        XCTAssertTrue(gate.isPaused)

        let resumed = expectation(description: "producer resumed on close")
        DispatchQueue.global().async {
            gate.waitUntilReadable()
            resumed.fulfill()
        }

        gate.close()
        wait(for: [resumed], timeout: 1.0)
        XCTAssertFalse(gate.isPaused)  // closed gates are never paused
    }

    func testNoBytesLostUnderConcurrentProduceConsume() {
        let gate = TerminalBackpressureGate(highWaterMark: 4096, lowWaterMark: 1024)
        let chunk = 64
        let iterations = 5000
        let total = chunk * iterations

        let lock = NSLock()
        var producedTotal = 0
        var producerDone = false

        let done = expectation(description: "done")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for _ in 0..<iterations {
                gate.waitUntilReadable()
                gate.produced(chunk)
                lock.lock()
                producedTotal += chunk
                lock.unlock()
            }
            lock.lock()
            producerDone = true
            lock.unlock()
            done.fulfill()
        }
        DispatchQueue.global().async {
            while true {
                let pending = gate.pendingByteCount
                if pending > 0 {
                    gate.consumed(pending)
                    continue
                }
                lock.lock()
                let finished = producerDone
                lock.unlock()
                if finished && gate.pendingByteCount == 0 { break }
                Thread.sleep(forTimeInterval: 0.001)
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        // Producer was never starved, and everything produced drained: no loss.
        XCTAssertEqual(producedTotal, total)
        XCTAssertEqual(gate.pendingByteCount, 0)
    }
}
