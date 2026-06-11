import Darwin
import Dispatch
import Foundation

/// Watches a set of directories for changes to their direct contents and fires a
/// debounced callback. A new entry is only visible in the browser when its parent
/// directory is the root or is expanded, so the actor watches exactly the root
/// plus the currently-expanded directories — that surfaces newly created files
/// right where the user is looking without recursively watching (and thrashing
/// on) collapsed or ignored subtrees.
///
/// An `actor`, so its mutable source table is isolated with no lock and no
/// `@unchecked Sendable`. The FSEvents sources target a private utility queue;
/// their `@Sendable` event handlers hop back onto the actor via `Task`. File
/// descriptors are closed by each source's cancel handler, so teardown happens
/// through `stop()` / source cancellation rather than an `isolated deinit`
/// (which crashes the release optimizer — DECISIONS-LOG D-011).
actor FileIndexDirectoryWatcher {
    private nonisolated let queue = DispatchQueue(
        label: "dev.dopsonbr.YAAW.file-index-watcher", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var onChange: (@Sendable () -> Void)?
    private var debounceTask: Task<Void, Never>?
    private let debounce: Duration

    /// Creates a watcher. `debounce` coalesces change bursts (350 ms default).
    init(debounce: DispatchTimeInterval = .milliseconds(350)) {
        switch debounce {
        case .milliseconds(let value):
            self.debounce = .milliseconds(value)
        case .seconds(let value):
            self.debounce = .seconds(value)
        case .microseconds(let value):
            self.debounce = .microseconds(value)
        case .nanoseconds(let value):
            self.debounce = .nanoseconds(value)
        default:
            self.debounce = .milliseconds(350)
        }
    }

    /// Replaces the watched set with `directories`, reusing descriptors for paths
    /// already watched and closing those no longer needed. All watched directories
    /// share `onChange`.
    func watch(directories: Set<String>, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        for path in Array(sources.keys) where !directories.contains(path) {
            remove(path: path)
        }
        for path in directories where sources[path] == nil {
            add(path: path)
        }
    }

    /// Stops watching every directory and clears the pending debounce.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        for path in Array(sources.keys) {
            remove(path: path)
        }
        onChange = nil
    }

    private func add(path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { await self?.scheduleDebouncedChange() }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        sources[path] = source
        source.resume()
    }

    private func remove(path: String) {
        sources[path]?.cancel()
        sources[path] = nil
    }

    private func scheduleDebouncedChange() {
        debounceTask?.cancel()
        let debounce = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.fireChange()
        }
    }

    private func fireChange() {
        onChange?()
    }
}
