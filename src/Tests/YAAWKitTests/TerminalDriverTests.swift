import XCTest

@testable import YAAWKit

final class TerminalDriverTests: XCTestCase {
    func testOutputPumpBatchesAdjacentOutputOnMainActor() async {
        let recorder = await MainActor.run { TerminalPumpRecorder() }
        let outputDelivered = expectation(description: "output delivered")
        let pump = AgentTerminalOutputPump(
            receive: { data in
                recorder.record("output:\(String(decoding: data, as: UTF8.self))")
                outputDelivered.fulfill()
            },
            finish: { _, _ in }
        )

        pump.enqueueOutput(Data("first".utf8))
        pump.enqueueOutput(Data("second".utf8))

        await fulfillment(of: [outputDelivered], timeout: 1)
        let events = await MainActor.run { recorder.events }
        XCTAssertEqual(events, ["output:firstsecond"])
    }

    func testOutputPumpDeliversFinishAfterPendingOutput() async {
        let recorder = await MainActor.run { TerminalPumpRecorder() }
        let finishDelivered = expectation(description: "finish delivered")
        let pump = AgentTerminalOutputPump(
            receive: { data in
                recorder.record("output:\(String(decoding: data, as: UTF8.self))")
            },
            finish: { exitCode, runtimeMilliseconds in
                recorder.record("finish:\(exitCode):\(runtimeMilliseconds)")
                finishDelivered.fulfill()
            }
        )

        pump.enqueueOutput(Data("final output".utf8))
        pump.enqueueFinish(exitCode: 7, runtimeMilliseconds: 42)

        await fulfillment(of: [finishDelivered], timeout: 1)
        let events = await MainActor.run { recorder.events }
        XCTAssertEqual(events, ["output:final output", "finish:7:42"])
    }

    func testOperationDriverSerializesOperationsAndSkipsDuplicateResizes() {
        let events = LockedTerminalDriverEvents()
        let initialViewport = AgentTerminalViewport(columns: 80, rows: 24)
        let resizedViewport = AgentTerminalViewport(columns: 101, rows: 33)
        let driver = AgentTerminalOperationDriver(
            queueLabel: "dev.dopsonbr.yaaw.tests.terminal-driver.\(UUID().uuidString)",
            start: { viewport in
                events.append("start:\(viewport.columns)x\(viewport.rows)")
            },
            resize: { viewport in
                events.append("resize:\(viewport.columns)x\(viewport.rows)")
            },
            write: { data in
                events.append("write:\(String(decoding: data, as: UTF8.self))")
            },
            terminate: {
                events.append("terminate")
            },
            onLaunchFailure: { error in
                events.append("failure:\(error)")
            }
        )

        driver.resizeOrStart(to: initialViewport)
        driver.resizeOrStart(to: initialViewport)
        driver.resizeOrStart(to: resizedViewport)
        driver.resizeOrStart(to: resizedViewport)
        driver.write(Data("input".utf8))
        driver.terminate()

        XCTAssertTrue(events.waitUntilCount(4))
        XCTAssertEqual(
            events.snapshot,
            ["start:80x24", "resize:101x33", "write:input", "terminate"]
        )
    }

    func testOperationDriverSendsStartupInputThroughDriverQueueAfterStart() {
        let events = LockedTerminalDriverEvents()
        let driver = AgentTerminalOperationDriver(
            queueLabel: "dev.dopsonbr.yaaw.tests.terminal-startup.\(UUID().uuidString)",
            startupInput: Data("boot".utf8),
            startupInputDelay: 0.01,
            start: { viewport in
                events.append("start:\(viewport.columns)x\(viewport.rows)")
            },
            resize: { viewport in
                events.append("resize:\(viewport.columns)x\(viewport.rows)")
            },
            write: { data in
                events.append("write:\(String(decoding: data, as: UTF8.self))")
            },
            terminate: {
                events.append("terminate")
            },
            onLaunchFailure: { error in
                events.append("failure:\(error)")
            }
        )

        driver.resizeOrStart(to: AgentTerminalViewport(columns: 80, rows: 24))

        XCTAssertTrue(events.waitUntilCount(2))
        XCTAssertEqual(events.snapshot, ["start:80x24", "write:boot"])
    }
}

@MainActor
private final class TerminalPumpRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private final class LockedTerminalDriverEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func append(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func waitUntilCount(_ count: Int, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshot.count >= count {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return snapshot.count >= count
    }
}
