import XCTest

@testable import YAAWKit

final class TerminalDriverTests: XCTestCase {
    func testOutputPumpBatchesAdjacentOutput() async {
        let recorder = TerminalPumpRecorder()
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
        XCTAssertEqual(recorder.snapshot, ["output:firstsecond"])
    }

    func testOutputPumpDeliversFinishAfterPendingOutput() async {
        let recorder = TerminalPumpRecorder()
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
        XCTAssertEqual(recorder.snapshot, ["output:final output", "finish:7:42"])
    }

    func testOutputPumpChunksLargeOutputInOrder() async {
        let recorder = TerminalPumpRecorder()
        let outputDelivered = expectation(description: "all output chunks delivered")
        outputDelivered.expectedFulfillmentCount = 3
        let pump = AgentTerminalOutputPump(
            maximumDeliveryBytes: 5,
            receive: { data in
                recorder.record("output:\(String(decoding: data, as: UTF8.self))")
                outputDelivered.fulfill()
            },
            finish: { _, _ in }
        )

        pump.enqueueOutput(Data("abcdefghijk".utf8))

        await fulfillment(of: [outputDelivered], timeout: 1)
        XCTAssertEqual(recorder.snapshot, ["output:abcde", "output:fghij", "output:k"])
    }

    func testOutputPumpDelaysFinishUntilChunkedOutputCompletes() async {
        let recorder = TerminalPumpRecorder()
        let finishDelivered = expectation(description: "finish delivered")
        let pump = AgentTerminalOutputPump(
            maximumDeliveryBytes: 4,
            receive: { data in
                recorder.record("output:\(String(decoding: data, as: UTF8.self))")
            },
            finish: { exitCode, runtimeMilliseconds in
                recorder.record("finish:\(exitCode):\(runtimeMilliseconds)")
                finishDelivered.fulfill()
            }
        )

        pump.enqueueOutput(Data("abcdef".utf8))
        pump.enqueueFinish(exitCode: 9, runtimeMilliseconds: 12)

        await fulfillment(of: [finishDelivered], timeout: 1)
        XCTAssertEqual(recorder.snapshot, ["output:abcd", "output:ef", "finish:9:12"])
    }

    func testOutputPumpRecordsSlowDeliveryDiagnostics() async {
        let diagnostics = LockedDiagnosticRecorder()
        let outputDelivered = expectation(description: "output delivered")
        let pump = AgentTerminalOutputPump(
            slowDeliveryThreshold: 0,
            diagnostics: diagnostics,
            receive: { _ in
                outputDelivered.fulfill()
            },
            finish: { _, _ in }
        )

        pump.enqueueOutput(Data("diagnose".utf8))

        await fulfillment(of: [outputDelivered], timeout: 1)
        XCTAssertTrue(diagnostics.waitUntilCount(1))
        XCTAssertEqual(diagnostics.snapshot.first?.category, "Terminal")
        XCTAssertEqual(diagnostics.snapshot.first?.name, "terminal_output_delivery_slow")
        XCTAssertEqual(diagnostics.snapshot.first?.metadata["bytes"], "8")
    }

    func testOutputPumpDoesNotBlockMainActorWhenReceiveBlocks() async {
        let diagnostics = LockedDiagnosticRecorder()
        let receiveStarted = expectation(description: "receive started")
        let mainActorReached = expectation(description: "main actor reached")
        let releaseReceive = DispatchSemaphore(value: 0)
        let pump = AgentTerminalOutputPump(
            blockedDeliveryThreshold: 0.05,
            diagnostics: diagnostics,
            receive: { _ in
                receiveStarted.fulfill()
                _ = releaseReceive.wait(timeout: .now() + 1)
            },
            finish: { _, _ in }
        )

        pump.enqueueOutput(Data("blocked".utf8))

        await fulfillment(of: [receiveStarted], timeout: 1)
        Task { @MainActor in
            mainActorReached.fulfill()
        }
        await fulfillment(of: [mainActorReached], timeout: 1)
        XCTAssertTrue(diagnostics.waitUntilName("terminal_output_delivery_blocked"))
        releaseReceive.signal()
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

private final class TerminalPumpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
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

private final class LockedDiagnosticRecorder: DiagnosticEventRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [DiagnosticEvent] = []

    var snapshot: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: DiagnosticEvent) {
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

    func waitUntilName(_ name: String, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshot.contains(where: { $0.name == name }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return snapshot.contains(where: { $0.name == name })
    }
}
