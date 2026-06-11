import Foundation

/// Serializes a store's persistence writes to the (async) store actor and lets
/// tests deterministically await them. Stores mutate `@Observable` state
/// synchronously (so the UI and tests see the new value immediately) and enqueue
/// the durable write here; the queue drains in FIFO order on a single chained
/// `Task`, preserving write ordering. `await flush()` resolves once every enqueued
/// write has completed — the seam the ported `AppModelTests` use to assert write
/// counters after a mutation.
@MainActor
final class StorePersistenceQueue {
    private let store: any YAAWStore
    private var tail: Task<Void, Never> = Task {}

    init(store: any YAAWStore) {
        self.store = store
    }

    /// Enqueues a write, chained after all previously enqueued writes.
    func enqueue(_ op: @escaping @Sendable (any YAAWStore) async -> Void) {
        let store = store
        let previous = tail
        tail = Task {
            await previous.value
            await op(store)
        }
    }

    /// Resolves once every enqueued write has completed.
    func flush() async {
        await tail.value
    }
}
