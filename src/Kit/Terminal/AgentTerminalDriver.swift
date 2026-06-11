import Foundation

/// Serializes PTY output into ordered, chunked deliveries to the consumer.
///
/// Output is queued on a dedicated GCD delivery queue and batched: adjacent
/// ``enqueueOutput(_:)`` calls coalesce into a single delivery, and large data
/// is split into at most `maximumDeliveryBytes` per delivery (in order). A
/// `finish` event is deferred until all queued output has drained. The pump
/// records diagnostics when the consumer's `receive` handler is slow
/// (>`slowDeliveryThreshold`) or blocked (>`blockedDeliveryThreshold`).
///
/// Deliberately `@unchecked Sendable`: a proven, ported lock-based primitive
/// (`NSLock` guarding the queue state plus a serial `DispatchQueue`). The
/// blocking, ordered delivery semantics depend on the lock + queue and would be
/// broken by converting it to an actor.
public final class AgentTerminalOutputPump: @unchecked Sendable {
    /// Receives a chunk of output to deliver downstream.
    public typealias ReceiveHandler = @Sendable (Data) -> Void
    /// Receives the finish event: exit code and runtime in milliseconds.
    public typealias FinishHandler = @Sendable (UInt32, UInt64) -> Void

    private struct FinishEvent {
        var exitCode: UInt32
        var runtimeMilliseconds: UInt64
    }

    private let lock = NSLock()
    private let receiveHandler: ReceiveHandler
    private let finishHandler: FinishHandler
    /// Called after each chunk is delivered, with the delivered byte count.
    /// Used to drive backpressure (signals the read loop that bytes drained).
    private let onDelivered: (@Sendable (Int) -> Void)?
    private let diagnostics: DiagnosticEventRecording?
    private let maximumDeliveryBytes: Int
    private let slowDeliveryThreshold: TimeInterval
    private let blockedDeliveryThreshold: TimeInterval
    private let deliveryQueue: DispatchQueue
    private var pendingData = Data()
    private var pendingFinish: FinishEvent?
    private var isFlushScheduled = false
    private var activeDeliveryID: UUID?

    /// Creates an output pump.
    ///
    /// - Parameters:
    ///   - maximumDeliveryBytes: Max bytes per delivery (default 32 KB).
    ///   - slowDeliveryThreshold: Delivery duration that logs a "slow" event.
    ///   - blockedDeliveryThreshold: Delivery duration that logs a "blocked" event.
    ///   - diagnostics: Optional sink for slow/blocked diagnostics.
    ///   - queueLabel: Label for the delivery queue.
    ///   - receive: Handler called with each delivered chunk.
    ///   - finish: Handler called once after all output drains.
    ///   - onDelivered: Optional callback with delivered byte counts (backpressure).
    public init(
        maximumDeliveryBytes: Int = 32 * 1024,
        slowDeliveryThreshold: TimeInterval = 0.1,
        blockedDeliveryThreshold: TimeInterval = 2,
        diagnostics: DiagnosticEventRecording? = nil,
        queueLabel: String = "dev.dopsonbr.yaaw.agent-terminal-output.\(UUID().uuidString)",
        receive: @escaping ReceiveHandler,
        finish: @escaping FinishHandler,
        onDelivered: (@Sendable (Int) -> Void)? = nil
    ) {
        self.maximumDeliveryBytes = max(1, maximumDeliveryBytes)
        self.slowDeliveryThreshold = slowDeliveryThreshold
        self.blockedDeliveryThreshold = blockedDeliveryThreshold
        self.diagnostics = diagnostics
        self.deliveryQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.receiveHandler = receive
        self.finishHandler = finish
        self.onDelivered = onDelivered
    }

    /// Enqueues output bytes for ordered, batched delivery.
    public func enqueueOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pendingData.append(data)
        scheduleFlushIfNeededLocked()
        lock.unlock()
    }

    /// Enqueues a finish event, delivered after all pending output drains.
    public func enqueueFinish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        lock.lock()
        pendingFinish = FinishEvent(
            exitCode: exitCode,
            runtimeMilliseconds: runtimeMilliseconds
        )
        scheduleFlushIfNeededLocked()
        lock.unlock()
    }

    private func scheduleFlushIfNeededLocked() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        deliveryQueue.async { [weak self] in
            self?.flushOnDeliveryQueue()
        }
    }

    private func flushOnDeliveryQueue() {
        lock.lock()
        let deliveryByteCount = min(pendingData.count, maximumDeliveryBytes)
        let data = Data(pendingData.prefix(deliveryByteCount))
        pendingData.removeFirst(deliveryByteCount)
        let remainingBytes = pendingData.count
        let finish = remainingBytes == 0 ? pendingFinish : nil
        if finish != nil {
            pendingFinish = nil
        }
        isFlushScheduled = false
        lock.unlock()

        if !data.isEmpty {
            let deliveryID = startDeliveryWatchdog(
                byteCount: data.count,
                remainingBytes: remainingBytes
            )
            let startedAt = Date()
            receiveHandler(data)
            finishDelivery(deliveryID)
            onDelivered?(data.count)
            recordSlowDeliveryIfNeeded(
                byteCount: data.count,
                remainingBytes: remainingBytes,
                duration: Date().timeIntervalSince(startedAt)
            )
        }
        if let finish {
            finishHandler(finish.exitCode, finish.runtimeMilliseconds)
        }

        lock.lock()
        let shouldScheduleAgain = !pendingData.isEmpty || pendingFinish != nil
        if shouldScheduleAgain {
            scheduleFlushIfNeededLocked()
        }
        lock.unlock()
    }

    private func startDeliveryWatchdog(byteCount: Int, remainingBytes: Int) -> UUID {
        guard diagnostics != nil, blockedDeliveryThreshold > 0 else { return UUID() }
        let deliveryID = UUID()
        lock.lock()
        activeDeliveryID = deliveryID
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + blockedDeliveryThreshold)
        {
            [weak self] in
            self?.recordBlockedDeliveryIfNeeded(
                deliveryID: deliveryID,
                byteCount: byteCount,
                remainingBytes: remainingBytes
            )
        }
        return deliveryID
    }

    private func finishDelivery(_ deliveryID: UUID) {
        lock.lock()
        if activeDeliveryID == deliveryID {
            activeDeliveryID = nil
        }
        lock.unlock()
    }

    private func recordBlockedDeliveryIfNeeded(
        deliveryID: UUID,
        byteCount: Int,
        remainingBytes: Int
    ) {
        lock.lock()
        let isBlocked = activeDeliveryID == deliveryID
        lock.unlock()
        guard isBlocked else { return }
        diagnostics?.record(
            DiagnosticEvent(
                category: "Terminal",
                name: "terminal_output_delivery_blocked",
                metadata: [
                    "bytes": "\(byteCount)",
                    "blocked_ms": "\(Int((blockedDeliveryThreshold * 1000).rounded()))",
                    "remaining_bytes": "\(remainingBytes)",
                ]))
    }

    private func recordSlowDeliveryIfNeeded(
        byteCount: Int,
        remainingBytes: Int,
        duration: TimeInterval
    ) {
        guard duration >= slowDeliveryThreshold else { return }
        diagnostics?.record(
            DiagnosticEvent(
                category: "Terminal",
                name: "terminal_output_delivery_slow",
                metadata: [
                    "bytes": "\(byteCount)",
                    "duration_ms": "\(Int((duration * 1000).rounded()))",
                    "remaining_bytes": "\(remainingBytes)",
                ]))
    }
}

/// Drives an ``AgentTerminalProcess`` through a serialized operation queue.
///
/// Resize-or-start, write, and terminate operations are serialized so the
/// process is started exactly once and resizes are coalesced. Startup input is
/// sent (once) through the same queue after launch.
///
/// Plainly `Sendable`: it holds only an immutable, `Sendable`
/// ``AgentTerminalOperationDriver`` and forwards to it, so it carries no mutable
/// state of its own and needs no `@unchecked` escape hatch.
public final class AgentTerminalProcessDriver: Sendable {
    private let operationDriver: AgentTerminalOperationDriver

    /// Creates a driver bound to `process`.
    ///
    /// - Parameters:
    ///   - process: The process to drive.
    ///   - startupInput: Optional input to send after launch.
    ///   - startupInputDelay: Delay before sending startup input (default 0.7 s).
    ///   - onLaunchFailure: Called if `start` throws.
    public init(
        process: AgentTerminalProcess,
        startupInput: String?,
        startupInputDelay: TimeInterval = 0.7,
        onLaunchFailure: @escaping @Sendable (Error) -> Void
    ) {
        let startupInputData =
            startupInput
            .flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
        self.operationDriver = AgentTerminalOperationDriver(
            startupInput: startupInputData,
            startupInputDelay: startupInputDelay,
            start: { viewport in
                try process.start(initialViewport: viewport)
            },
            resize: { viewport in
                process.resize(to: viewport)
            },
            write: { data in
                process.write(data)
            },
            terminate: {
                process.terminate()
            },
            onLaunchFailure: onLaunchFailure
        )
    }

    /// Starts the process (first call) or resizes it (subsequent calls).
    public func resizeOrStart(to viewport: AgentTerminalViewport) {
        operationDriver.resizeOrStart(to: viewport)
    }

    /// Writes input to the process.
    public func write(_ data: Data) {
        operationDriver.write(data)
    }

    /// Terminates the process.
    public func terminate() {
        operationDriver.terminate()
    }
}

/// Serializes terminal start/resize/write/terminate operations onto one queue.
///
/// Deliberately `@unchecked Sendable`: a proven, ported lock/queue primitive —
/// the operation driver named in the plan's "operation/process drivers" KEEP
/// list. Its mutable `hasStarted`/`lastViewport` are guarded solely by the
/// serial `DispatchQueue`; the single-start + resize-coalescing invariants
/// (covered directly by `TerminalDriverTests`) depend on that queue, which an
/// actor conversion would not preserve identically.
final class AgentTerminalOperationDriver: @unchecked Sendable {
    typealias StartHandler = @Sendable (AgentTerminalViewport) throws -> Void
    typealias ResizeHandler = @Sendable (AgentTerminalViewport) -> Void
    typealias WriteHandler = @Sendable (Data) -> Void
    typealias TerminateHandler = @Sendable () -> Void
    typealias LaunchFailureHandler = @Sendable (Error) -> Void

    private let queue: DispatchQueue
    private let startupInput: Data?
    private let startupInputDelay: TimeInterval
    private let startHandler: StartHandler
    private let resizeHandler: ResizeHandler
    private let writeHandler: WriteHandler
    private let terminateHandler: TerminateHandler
    private let launchFailureHandler: LaunchFailureHandler
    private var hasStarted = false
    private var lastViewport: AgentTerminalViewport?

    init(
        queueLabel: String = "dev.dopsonbr.yaaw.agent-terminal-driver.\(UUID().uuidString)",
        startupInput: Data? = nil,
        startupInputDelay: TimeInterval = 0.7,
        start: @escaping StartHandler,
        resize: @escaping ResizeHandler,
        write: @escaping WriteHandler,
        terminate: @escaping TerminateHandler,
        onLaunchFailure: @escaping LaunchFailureHandler
    ) {
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.startupInput = startupInput
        self.startupInputDelay = startupInputDelay
        self.startHandler = start
        self.resizeHandler = resize
        self.writeHandler = write
        self.terminateHandler = terminate
        self.launchFailureHandler = onLaunchFailure
    }

    func resizeOrStart(to viewport: AgentTerminalViewport) {
        queue.async { [weak self] in
            self?.performResizeOrStart(to: viewport)
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            self?.writeHandler(data)
        }
    }

    func terminate() {
        queue.async { [weak self] in
            self?.terminateHandler()
        }
    }

    private func performResizeOrStart(to viewport: AgentTerminalViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }
        if hasStarted {
            guard lastViewport != viewport else { return }
            lastViewport = viewport
            resizeHandler(viewport)
            return
        }
        do {
            try startHandler(viewport)
            hasStarted = true
            lastViewport = viewport
            sendStartupInputIfNeeded()
        } catch {
            launchFailureHandler(error)
        }
    }

    private func sendStartupInputIfNeeded() {
        guard let startupInput, !startupInput.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + startupInputDelay) { [weak self] in
            self?.writeHandler(startupInput)
        }
    }
}
