import Darwin
import Dispatch
import Foundation

public final class FileIndexDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.dopsonbr.YAAW.file-index-watcher", qos: .utility)
    private var watchedPath: String?
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?

    public init() {}

    deinit {
        stop()
    }

    public func watch(root: URL, onChange: @escaping @Sendable () -> Void) {
        let path = root.standardizedFileURL.path
        queue.async { [weak self] in
            guard let self else { return }
            guard watchedPath != path else { return }
            stopLocked()

            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            fileDescriptor = descriptor
            watchedPath = path

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebouncedChange(onChange: onChange)
            }
            source.setCancelHandler { [descriptor] in
                close(descriptor)
            }
            self.source = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func scheduleDebouncedChange(onChange: @escaping @Sendable () -> Void) {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem {
            DispatchQueue.main.async(execute: onChange)
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(350), execute: item)
    }

    private func stopLocked() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
        watchedPath = nil
        fileDescriptor = -1
    }
}
