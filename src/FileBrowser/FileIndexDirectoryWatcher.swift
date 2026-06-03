import Darwin
import Dispatch
import Foundation

/// Watches a set of directories for changes to their direct contents and fires a debounced
/// callback. A new entry is only visible in the browser when its parent directory is the root
/// or is expanded, so the model watches exactly the root plus the currently-expanded
/// directories — that surfaces newly created files right where the user is looking without
/// recursively watching (and thrashing on) collapsed or ignored subtrees.
public final class FileIndexDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.dopsonbr.YAAW.file-index-watcher", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    deinit {
        stop()
    }

    /// Replaces the watched set with `directories`, reusing descriptors for paths already
    /// watched and closing those no longer needed. All watched directories share `onChange`.
    public func watch(directories: Set<String>, onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange
            for path in Array(sources.keys) where !directories.contains(path) {
                removeLocked(path: path)
            }
            for path in directories where sources[path] == nil {
                addLocked(path: path)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func addLocked(path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedChange()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        sources[path] = source
        source.resume()
    }

    private func removeLocked(path: String) {
        sources[path]?.cancel()
        sources[path] = nil
    }

    private func scheduleDebouncedChange() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let onChange = self?.onChange else { return }
            DispatchQueue.main.async(execute: onChange)
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + .milliseconds(350), execute: item)
    }

    private func stopLocked() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        for path in Array(sources.keys) {
            removeLocked(path: path)
        }
        onChange = nil
    }
}
