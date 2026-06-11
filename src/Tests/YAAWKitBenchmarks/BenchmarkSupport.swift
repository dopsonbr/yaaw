import Foundation
import XCTest

enum BenchmarkSupport {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] == "1"
    }()

    static func skipUnlessEnabled(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            isEnabled, "set RUN_BENCHMARKS=1 to run benchmarks", file: file, line: line)
    }

    static func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWBench-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Median wall-clock time of a synchronous `body` across `iterations` runs.
    static func median(iterations: Int, _ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<iterations {
            let start = clock.now
            body()
            samples.append(clock.now - start)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// Prints a `BENCH …` line in milliseconds for a measured `duration`.
    static func report(_ label: String, _ duration: Duration) {
        let millis =
            Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1_000
        print("BENCH \(label): \(String(format: "%.3f", millis)) ms (median)")
    }
}

// NOTE: this base class deliberately does NOT override `defaultMetrics` with
// `XCTClockMetric`. Benchmarks time work with `ContinuousClock` directly, and
// referencing `XCTMetric` here crashes the Swift 6.3 release optimizer when the
// benchmark module also imports YAAWKit (DECISIONS-LOG D-010), which would break
// the `swift test -c release` perf gate.
class BenchmarkCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try BenchmarkSupport.skipUnlessEnabled()
    }
}
