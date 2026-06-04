import Foundation

public final class AgentTerminalOutputPump: @unchecked Sendable {
    public typealias ReceiveHandler = @MainActor (Data) -> Void
    public typealias FinishHandler = @MainActor (UInt32, UInt64) -> Void

    private struct FinishEvent {
        var exitCode: UInt32
        var runtimeMilliseconds: UInt64
    }

    private let lock = NSLock()
    private let receiveHandler: ReceiveHandler
    private let finishHandler: FinishHandler
    private let diagnostics: DiagnosticEventRecording?
    private let maximumDeliveryBytes: Int
    private let slowDeliveryThreshold: TimeInterval
    private var pendingData = Data()
    private var pendingFinish: FinishEvent?
    private var isFlushScheduled = false

    public init(
        maximumDeliveryBytes: Int = 32 * 1024,
        slowDeliveryThreshold: TimeInterval = 0.1,
        diagnostics: DiagnosticEventRecording? = nil,
        receive: @escaping ReceiveHandler,
        finish: @escaping FinishHandler
    ) {
        self.maximumDeliveryBytes = max(1, maximumDeliveryBytes)
        self.slowDeliveryThreshold = slowDeliveryThreshold
        self.diagnostics = diagnostics
        self.receiveHandler = receive
        self.finishHandler = finish
    }

    public func enqueueOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pendingData.append(data)
        scheduleFlushIfNeededLocked()
        lock.unlock()
    }

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
        Task { @MainActor [weak self] in
            self?.flushOnMainActor()
        }
    }

    @MainActor
    private func flushOnMainActor() {
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
            let startedAt = Date()
            receiveHandler(data)
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

public final class AgentTerminalProcessDriver: @unchecked Sendable {
    private let operationDriver: AgentTerminalOperationDriver

    public init(
        process: AgentTerminalProcess,
        startupInput: String?,
        startupInputDelay: TimeInterval = 0.7,
        onLaunchFailure: @escaping @Sendable (Error) -> Void
    ) {
        let startupInputData = startupInput
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

    public func resizeOrStart(to viewport: AgentTerminalViewport) {
        operationDriver.resizeOrStart(to: viewport)
    }

    public func write(_ data: Data) {
        operationDriver.write(data)
    }

    public func terminate() {
        operationDriver.terminate()
    }
}

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
