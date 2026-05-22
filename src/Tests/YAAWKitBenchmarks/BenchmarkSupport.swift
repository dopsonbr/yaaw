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
}

class BenchmarkCase: XCTestCase {
    override class var defaultMetrics: [XCTMetric] {
        [XCTClockMetric()]
    }

    override func setUp() async throws {
        try await super.setUp()
        try BenchmarkSupport.skipUnlessEnabled()
    }
}
