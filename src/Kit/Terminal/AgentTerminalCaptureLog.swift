import Foundation

/// Constants for the terminal PTY capture log.
public enum AgentTerminalCaptureLog {
    /// Default maximum capture-log size (8 MB) before the circular buffer wraps.
    public static let maximumBytes: UInt64 = 8 * 1024 * 1024
}

/// A circular (truncate-and-restart) capture log writer for PTY output.
///
/// Appends bytes to a file; when the next append would exceed `maximumBytes`,
/// the file is removed and recreated (the buffer wraps). Appends are serialized
/// under an `NSLock`; the parent directory is created lazily; file I/O errors
/// are swallowed (capture is best-effort, never fatal).
///
/// Truncation is **surfaced**, not silent: an optional `onTruncated` callback
/// fires with the byte offset at which the buffer wrapped, so the host can emit
/// a `RenderEvent.captureTruncated(truncatedAtByte:)` and the app can notify the
/// user that earlier capture was discarded.
///
/// Deliberately `@unchecked Sendable`: a proven, ported lock-based primitive
/// (`NSLock` serializing appends). It performs blocking file I/O under the lock,
/// which an actor conversion would not preserve.
public final class AgentTerminalCaptureWriter: @unchecked Sendable {
    private let url: URL
    private let maximumBytes: UInt64
    private let onTruncated: (@Sendable (UInt64) -> Void)?
    private let lock = NSLock()
    private var knownSize: UInt64?

    /// Creates a capture writer.
    ///
    /// - Parameters:
    ///   - url: The capture-log file location.
    ///   - maximumBytes: Size at which the buffer wraps (default 8 MB).
    ///   - onTruncated: Optional callback fired (with the byte offset at which the
    ///     buffer wrapped) each time the circular buffer discards earlier bytes.
    public init(
        url: URL,
        maximumBytes: UInt64 = AgentTerminalCaptureLog.maximumBytes,
        onTruncated: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.onTruncated = onTruncated
    }

    /// Appends `data` to the capture log, wrapping the buffer if it would
    /// overflow `maximumBytes`. Fires `onTruncated` when a wrap occurs.
    public func append(_ data: Data) {
        guard !data.isEmpty, maximumBytes > 0 else { return }
        lock.lock()
        var truncatedAtByte: UInt64?
        defer {
            lock.unlock()
            if let truncatedAtByte {
                onTruncated?(truncatedAtByte)
            }
        }

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
                truncatedAtByte = currentSize
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
