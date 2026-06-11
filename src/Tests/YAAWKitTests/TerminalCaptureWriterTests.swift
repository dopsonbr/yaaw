import XCTest

@testable import YAAWKit

final class TerminalCaptureWriterTests: XCTestCase {
    func testAppendCreatesParentDirectoryAndWritesBytes() throws {
        let url = try temporaryCaptureURL()
        let writer = AgentTerminalCaptureWriter(url: url, maximumBytes: 1024)

        writer.append(Data("hello".utf8))

        let contents = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: contents, as: UTF8.self), "hello")
    }

    func testCircularBufferTruncatesAndFiresTruncationCallback() throws {
        let url = try temporaryCaptureURL()
        let truncated = LockedByteOffsets()
        let writer = AgentTerminalCaptureWriter(
            url: url,
            maximumBytes: 8,
            onTruncated: { offset in truncated.append(offset) }
        )

        writer.append(Data("abcdef".utf8))  // 6 bytes, fits
        XCTAssertTrue(truncated.snapshot.isEmpty)

        // 6 + 4 = 10 > 8 → wrap: file removed and restarted at the new bytes.
        writer.append(Data("ghij".utf8))

        let contents = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: contents, as: UTF8.self), "ghij")
        XCTAssertEqual(truncated.snapshot, [6])
    }

    func testOversizedAppendKeepsOnlyTrailingMaximumBytes() throws {
        let url = try temporaryCaptureURL()
        let writer = AgentTerminalCaptureWriter(url: url, maximumBytes: 4)

        writer.append(Data("abcdefgh".utf8))  // 8 bytes > 4 max

        let contents = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: contents, as: UTF8.self), "efgh")
    }

    private func temporaryCaptureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("capture.log")
    }
}

private final class LockedByteOffsets: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [UInt64] = []

    var snapshot: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return offsets
    }

    func append(_ offset: UInt64) {
        lock.lock()
        offsets.append(offset)
        lock.unlock()
    }
}
