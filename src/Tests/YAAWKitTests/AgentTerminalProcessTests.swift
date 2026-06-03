import Foundation
import XCTest

@testable import YAAWKit

final class AgentTerminalProcessTests: XCTestCase {
    /// Input written before `start()` (and before the agent is interactive) must be
    /// buffered and replayed once the child produces its first output, rather than
    /// silently dropped. This is the regression that forced users to send the first
    /// message to a new thread twice.
    /// Thread-safe accumulator so the `@Sendable` output handler can collect bytes.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func testBuffersPreStartInputAndFlushesAfterFirstOutput() throws {
        let outputReceived = expectation(description: "buffered input is echoed back")
        outputReceived.assertForOverFulfill = false
        let collector = OutputCollector()

        let process = AgentTerminalProcess(
            command: ["/bin/sh", "-c", "echo ready; cat"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            environment: ["PATH": "/usr/bin:/bin"],
            output: { data in
                collector.append(data)
                if collector.text.contains("hello-yaaw") {
                    outputReceived.fulfill()
                }
            }
        )
        defer { process.terminate() }

        // Write before the process is started: must be buffered, not dropped.
        process.write(Data("hello-yaaw\n".utf8))
        try process.start(
            initialViewport: AgentTerminalViewport(columns: 80, rows: 24)
        )

        wait(for: [outputReceived], timeout: 5.0)
    }
}
