import Foundation

public enum AgentTerminalCaptureLog {
    public static let maximumBytes: UInt64 = 8 * 1024 * 1024
}

public final class AgentTerminalCaptureWriter: @unchecked Sendable {
    private let url: URL
    private let maximumBytes: UInt64
    private let lock = NSLock()
    private var knownSize: UInt64?

    public init(url: URL, maximumBytes: UInt64 = AgentTerminalCaptureLog.maximumBytes) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    public func append(_ data: Data) {
        guard !data.isEmpty, maximumBytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var bytesToWrite = data
            if UInt64(bytesToWrite.count) > maximumBytes {
                bytesToWrite = bytesToWrite.suffix(Int(maximumBytes))
            }

            let currentSize = try currentFileSize()
            if currentSize + UInt64(bytesToWrite.count) > maximumBytes {
                try? FileManager.default.removeItem(at: url)
                knownSize = 0
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytesToWrite)
            knownSize = (knownSize ?? 0) + UInt64(bytesToWrite.count)
        } catch {
            return
        }
    }

    private func currentFileSize() throws -> UInt64 {
        if let knownSize {
            return knownSize
        }
        let size =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        knownSize = size
        return size
    }
}
