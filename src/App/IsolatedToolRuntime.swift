import AppKit
import Combine
import Foundation
import YAAWKit

struct IsolatedTerminalEventHandlers {
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }
    var onDesktopNotification: (TerminalRole, String, String) -> Void = { _, _, _ in }
    var onFocusChange: (TerminalRole, Bool) -> Void = { _, _ in }
    var onClose: (TerminalRole) -> Void = { _ in }
    var onCommandFinished: (TerminalRole, Int?) -> Void = { _, _ in }
}

@MainActor
final class IsolatedToolRuntime: ObservableObject {
    @Published private(set) var snapshotsByInstanceID: [String: IsolatedToolRuntimeSnapshot] = [:]

    var onNewSurfaceRequested: ((String) -> Void)?
    var onKeyboardShortcut: ((String, [String]) -> Void)?

    private var hostsByInstanceID: [String: IsolatedToolHostProcess] = [:]
    private var terminalLaunchesByInstanceID: [String: IsolatedTerminalLaunch] = [:]
    private var terminalHandlersByInstanceID:
        [String: (role: TerminalRole, handlers: IsolatedTerminalEventHandlers)] = [:]
    private let helperURLProvider: @MainActor () -> URL?

    init(helperURLProvider: @escaping @MainActor () -> URL? = IsolatedToolRuntime.defaultHelperURL)
    {
        self.helperURLProvider = helperURLProvider
    }

    func snapshot(for instanceID: String) -> IsolatedToolRuntimeSnapshot {
        snapshotsByInstanceID[instanceID] ?? IsolatedToolRuntimeSnapshot()
    }

    func ensureLaunched(kind: IsolatedToolKind, instanceID: String) {
        guard startHost(kind: kind, instanceID: instanceID) else { return }
        send(type: "launchTool", kind: kind, instanceID: instanceID)
    }

    /// Spawns the helper process if one is not already running for `instanceID`.
    /// Returns `true` only when a fresh process was started (so callers can send
    /// a one-time launch message). Sends no IPC itself.
    @discardableResult
    private func startHost(kind: IsolatedToolKind, instanceID: String) -> Bool {
        if hostsByInstanceID[instanceID] != nil { return false }
        guard let helperURL = helperURLProvider(),
            FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            apply(.crashed("Tool host executable is unavailable."), instanceID: instanceID)
            return false
        }

        apply(.launch, instanceID: instanceID)
        let hostID = UUID()
        let host = IsolatedToolHostProcess(
            hostID: hostID,
            helperURL: helperURL,
            kind: kind,
            instanceID: instanceID,
            onEvent: { [weak self] envelope in
                Task { @MainActor in
                    self?.handle(envelope)
                }
            },
            onExit: { [weak self] wasExpected in
                Task { @MainActor in
                    self?.handleExit(
                        instanceID: instanceID,
                        hostID: hostID,
                        wasExpected: wasExpected)
                }
            },
            onWriteFailure: { [weak self] in
                Task { @MainActor in
                    self?.handleWriteFailure(instanceID: instanceID, hostID: hostID)
                }
            }
        )
        hostsByInstanceID[instanceID] = host

        do {
            try host.start()
            return true
        } catch {
            hostsByInstanceID[instanceID] = nil
            apply(
                .crashed("Tool host failed to start: \(error.localizedDescription)"),
                instanceID: instanceID)
            return false
        }
    }

    func loadBrowser(instanceID: String, urlString: String) {
        // Browser is single-tenant: tear down sibling *browser* helpers. This is
        // now scoped to browser-kind hosts, so terminal helpers are unaffected.
        shutdownAll(except: instanceID)
        ensureLaunched(kind: .browser, instanceID: instanceID)
        send(
            type: "load",
            kind: .browser,
            instanceID: instanceID,
            payload: ["urlString": urlString]
        )
    }

    func browserBack(instanceID: String) {
        send(type: "goBack", kind: .browser, instanceID: instanceID)
    }

    func browserForward(instanceID: String) {
        send(type: "goForward", kind: .browser, instanceID: instanceID)
    }

    func browserReload(instanceID: String, urlString: String?) {
        let snapshot = snapshot(for: instanceID)
        if snapshot.phase == .crashed || snapshot.phase == .exited {
            restart(kind: .browser, instanceID: instanceID)
            if let urlString, !urlString.isEmpty {
                loadBrowser(instanceID: instanceID, urlString: urlString)
            }
        } else {
            send(type: "reload", kind: .browser, instanceID: instanceID)
        }
    }

    func browserStop(instanceID: String) {
        send(type: "stop", kind: .browser, instanceID: instanceID)
    }

    // MARK: - Terminal

    /// Spawns the terminal helper for `instanceID` (one per TerminalRole) if it
    /// is not already running, and sends the one-time launch config. Unlike the
    /// browser, the helper persists while the pane is hidden — the agent keeps
    /// running — and is only torn down by `terminalShutdown`.
    func ensureTerminalLaunched(
        instanceID: String,
        role: TerminalRole,
        launch: IsolatedTerminalLaunch,
        handlers: IsolatedTerminalEventHandlers
    ) {
        terminalHandlersByInstanceID[instanceID] = (role, handlers)
        if let existingLaunch = terminalLaunchesByInstanceID[instanceID],
            existingLaunch != launch
        {
            shutdown(instanceID: instanceID)
        }
        guard startHost(kind: .terminal, instanceID: instanceID) else { return }
        terminalLaunchesByInstanceID[instanceID] = launch
        send(
            type: "launchTerminal",
            kind: .terminal,
            instanceID: instanceID,
            payload: launch.payload())
    }

    func terminalSetViewport(
        instanceID: String,
        frame: CGRect,
        visible: Bool,
        shouldFloatToolHost: Bool
    ) {
        send(
            type: "setViewport",
            kind: .terminal,
            instanceID: instanceID,
            payload: Self.viewportPayload(
                frame: frame,
                visible: visible,
                shouldFloatToolHost: shouldFloatToolHost))
    }

    func terminalFocus(instanceID: String, focused: Bool) {
        send(type: focused ? "focus" : "blur", kind: .terminal, instanceID: instanceID)
    }

    /// Sends bytes to the child's PTY (paste, startup input, host-injected text).
    /// Interactive keystrokes go directly to the focused helper window.
    func terminalInput(instanceID: String, bytes: Data) {
        send(
            type: "input",
            kind: .terminal,
            instanceID: instanceID,
            payload: ["bytes": bytes.base64EncodedString()])
    }

    func terminalResize(instanceID: String, columns: Int, rows: Int) {
        send(
            type: "resize",
            kind: .terminal,
            instanceID: instanceID,
            payload: ["columns": String(columns), "rows": String(rows)])
    }

    /// Signals the hosted agent to terminate but keeps the helper alive to show
    /// the exited state. Use `terminalShutdown` to also tear down the helper.
    func terminalTerminate(instanceID: String) {
        send(type: "terminate", kind: .terminal, instanceID: instanceID)
    }

    func terminalShutdown(instanceID: String) {
        shutdown(instanceID: instanceID)
    }

    func setViewport(
        instanceID: String,
        frame: CGRect,
        visible: Bool,
        shouldFloatToolHost: Bool
    ) {
        // Browser is single-tenant: showing one hides sibling browsers. Scoped
        // to browser-kind hosts (see hideAll), so terminals are unaffected.
        if visible {
            hideAll(except: instanceID)
        }
        send(
            type: "setViewport",
            kind: .browser,
            instanceID: instanceID,
            payload: Self.viewportPayload(
                frame: frame,
                visible: visible,
                shouldFloatToolHost: shouldFloatToolHost))
    }

    func hide(instanceID: String) {
        send(type: "hide", kind: .browser, instanceID: instanceID)
    }

    /// Hides every *browser* host except the active one. Terminal helpers manage
    /// their own visibility per-instance and are intentionally left untouched.
    func hideAll(except activeInstanceID: String? = nil) {
        for (instanceID, host) in hostsByInstanceID
        where host.kind == .browser && (activeInstanceID.map { instanceID != $0 } ?? true) {
            hide(instanceID: instanceID)
        }
    }

    static func viewportPayload(
        frame: CGRect,
        visible: Bool,
        shouldFloatToolHost: Bool
    ) -> [String: String] {
        [
            "x": String(Double(frame.origin.x)),
            "y": String(Double(frame.origin.y)),
            "width": String(Double(frame.size.width)),
            "height": String(Double(frame.size.height)),
            "visible": String(visible),
            "shouldFloat": String(shouldFloatToolHost),
        ]
    }

    func restart(kind: IsolatedToolKind, instanceID: String) {
        hostsByInstanceID[instanceID]?.shutdown()
        hostsByInstanceID[instanceID] = nil
        apply(.launch, instanceID: instanceID)
        ensureLaunched(kind: kind, instanceID: instanceID)
    }

    func shutdown(instanceID: String) {
        hostsByInstanceID[instanceID]?.shutdown()
        hostsByInstanceID[instanceID] = nil
        terminalLaunchesByInstanceID[instanceID] = nil
        apply(.exited(nil), instanceID: instanceID)
    }

    func shutdownAllHosts() {
        for instanceID in Array(hostsByInstanceID.keys) {
            shutdown(instanceID: instanceID)
        }
    }

    /// Shuts down every *browser* host except the active one. Terminal helpers
    /// must keep running while their thread is live, so they are never torn
    /// down by this browser-lifecycle helper.
    func shutdownAll(except activeInstanceID: String? = nil) {
        let inactiveIDs = hostsByInstanceID.filter { instanceID, host in
            host.kind == .browser && (activeInstanceID.map { instanceID != $0 } ?? true)
        }.map(\.key)
        for instanceID in inactiveIDs {
            guard let host = hostsByInstanceID[instanceID] else { continue }
            host.shutdown()
            hostsByInstanceID[instanceID] = nil
            terminalLaunchesByInstanceID[instanceID] = nil
            apply(.exited(nil), instanceID: instanceID)
        }
    }

    private func send(
        type: String,
        kind: IsolatedToolKind,
        instanceID: String,
        payload: [String: String] = [:]
    ) {
        let envelope = IsolatedToolEnvelope(
            toolKind: kind,
            instanceID: instanceID,
            type: type,
            payload: payload
        )
        do {
            try hostsByInstanceID[instanceID]?.send(envelope)
        } catch {
            hostsByInstanceID[instanceID] = nil
            apply(
                .crashed("Tool host command failed: \(error.localizedDescription)"),
                instanceID: instanceID)
        }
    }

    private func handle(_ envelope: IsolatedToolEnvelope) {
        do {
            let envelope = try envelope.validated()
            switch envelope.type {
            case "ready":
                apply(.ready, instanceID: envelope.instanceID)
            case "stateChanged":
                apply(.stateChanged(envelope.payload), instanceID: envelope.instanceID)
            case "titleChanged":
                apply(
                    .titleChanged(envelope.payload["title"] ?? ""), instanceID: envelope.instanceID)
                notifyTerminalTitleChanged(envelope)
            case "desktopNotification":
                notifyTerminalDesktopNotification(envelope)
            case "focusChanged":
                notifyTerminalFocusChanged(envelope)
            case "closed":
                notifyTerminalClosed(envelope)
            case "commandFinished":
                notifyTerminalCommandFinished(envelope)
            case "keyboardShortcut":
                notifyKeyboardShortcut(envelope)
            case "error":
                apply(
                    .error(envelope.payload["message"] ?? "Tool host reported an error."),
                    instanceID: envelope.instanceID)
            case "exited":
                // Terminal kind: the hosted command finished but the helper
                // process stays alive to display the exited state.
                apply(
                    .exited(envelope.payload["exitCode"].flatMap { Int32($0) }),
                    instanceID: envelope.instanceID)
                notifyTerminalCommandFinished(envelope)
            case "newSurfaceRequested":
                if let urlString = envelope.payload["urlString"], !urlString.isEmpty {
                    onNewSurfaceRequested?(urlString)
                }
            default:
                apply(
                    .error("Tool host sent an unsupported event: \(envelope.type)"),
                    instanceID: envelope.instanceID)
            }
        } catch {
            apply(.crashed("Tool host protocol error: \(error)"), instanceID: envelope.instanceID)
        }
    }

    private func handleExit(instanceID: String, hostID: UUID, wasExpected: Bool) {
        guard hostsByInstanceID[instanceID]?.hostID == hostID else { return }
        hostsByInstanceID[instanceID] = nil
        terminalLaunchesByInstanceID[instanceID] = nil
        apply(
            wasExpected ? .exited(nil) : .crashed("Tool host exited unexpectedly."),
            instanceID: instanceID)
    }

    private func handleWriteFailure(instanceID: String, hostID: UUID) {
        guard let host = hostsByInstanceID[instanceID] else { return }
        guard host.hostID == hostID else { return }
        host.shutdown()
        hostsByInstanceID[instanceID] = nil
        terminalLaunchesByInstanceID[instanceID] = nil
        apply(.crashed("Tool host stopped responding."), instanceID: instanceID)
    }

    private func apply(_ action: IsolatedToolRuntimeAction, instanceID: String) {
        snapshotsByInstanceID[instanceID] = IsolatedToolRuntimeReducer.reduce(
            snapshot(for: instanceID),
            action: action
        )
    }

    private func terminalHandler(for instanceID: String)
        -> (role: TerminalRole, handlers: IsolatedTerminalEventHandlers)?
    {
        terminalHandlersByInstanceID[instanceID]
    }

    private func notifyTerminalTitleChanged(_ envelope: IsolatedToolEnvelope) {
        guard envelope.toolKind == .terminal,
            let handler = terminalHandler(for: envelope.instanceID)
        else { return }
        handler.handlers.onTitleChange(handler.role, envelope.payload["title"] ?? "")
    }

    private func notifyTerminalDesktopNotification(_ envelope: IsolatedToolEnvelope) {
        guard envelope.toolKind == .terminal,
            let handler = terminalHandler(for: envelope.instanceID)
        else { return }
        handler.handlers.onDesktopNotification(
            handler.role,
            envelope.payload["title"] ?? "",
            envelope.payload["body"] ?? ""
        )
    }

    private func notifyTerminalFocusChanged(_ envelope: IsolatedToolEnvelope) {
        guard envelope.toolKind == .terminal,
            let handler = terminalHandler(for: envelope.instanceID)
        else { return }
        handler.handlers.onFocusChange(
            handler.role,
            envelope.payload["focused"].flatMap(Bool.init) == true
        )
    }

    private func notifyTerminalClosed(_ envelope: IsolatedToolEnvelope) {
        guard envelope.toolKind == .terminal,
            let handler = terminalHandler(for: envelope.instanceID)
        else { return }
        handler.handlers.onClose(handler.role)
    }

    private func notifyTerminalCommandFinished(_ envelope: IsolatedToolEnvelope) {
        guard envelope.toolKind == .terminal,
            let handler = terminalHandler(for: envelope.instanceID)
        else { return }
        handler.handlers.onCommandFinished(
            handler.role,
            envelope.payload["exitCode"].flatMap(Int.init)
        )
    }

    private func notifyKeyboardShortcut(_ envelope: IsolatedToolEnvelope) {
        guard envelope.toolKind == .terminal,
            let key = envelope.payload["key"],
            !key.isEmpty
        else { return }
        let modifiers =
            envelope.payload["modifiers"]?
            .split(separator: ",")
            .map(String.init) ?? []
        onKeyboardShortcut?(key, modifiers)
    }

    private static func defaultHelperURL() -> URL? {
        let bundleHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("YAAWToolHost")
        if FileManager.default.isExecutableFile(atPath: bundleHelper.path) {
            return bundleHelper
        }

        guard let executableURL = Bundle.main.executableURL else { return nil }
        let sibling = executableURL.deletingLastPathComponent().appendingPathComponent(
            "YAAWToolHost")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        return nil
    }
}

private final class IsolatedToolHostProcess: @unchecked Sendable {
    /// Outbound stdin is bounded: if the helper stops draining (hung) we
    /// disconnect rather than letting the parent's writes accumulate or block.
    private static let maxPendingWriteBytes = 4 * 1024 * 1024

    fileprivate let hostID: UUID
    private let helperURL: URL
    fileprivate let kind: IsolatedToolKind
    private let instanceID: String
    private let onEvent: (IsolatedToolEnvelope) -> Void
    private let onExit: (Bool) -> Void
    private let onWriteFailure: () -> Void
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var outputBuffer = Data()
    private var expectedExit = false

    // All parent->helper writes go through this serial queue so the main
    // actor never blocks on a full pipe when a helper hangs.
    private let writeQueue: DispatchQueue
    private let writeLock = NSLock()
    private var pendingWriteBytes = 0
    private var writeBroken = false

    init(
        hostID: UUID,
        helperURL: URL,
        kind: IsolatedToolKind,
        instanceID: String,
        onEvent: @escaping (IsolatedToolEnvelope) -> Void,
        onExit: @escaping (Bool) -> Void,
        onWriteFailure: @escaping () -> Void
    ) {
        self.hostID = hostID
        self.helperURL = helperURL
        self.kind = kind
        self.instanceID = instanceID
        self.onEvent = onEvent
        self.onExit = onExit
        self.onWriteFailure = onWriteFailure
        self.writeQueue = DispatchQueue(
            label: "dev.dopsonbr.yaaw.isolated-tool-write.\(instanceID)")
    }

    func start() throws {
        process.executableURL = helperURL
        process.arguments = ["--tool-kind", kind.rawValue, "--instance-id", instanceID]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.outputPipe.fileHandleForReading.readabilityHandler = nil
            self.onExit(self.expectedExit)
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readAvailableOutput(from: handle)
        }
        try process.run()
    }

    func send(_ envelope: IsolatedToolEnvelope) throws {
        let line = try JSONEncoder().encode(envelope) + Data([0x0A])

        writeLock.lock()
        if writeBroken {
            writeLock.unlock()
            return
        }
        if pendingWriteBytes + line.count > Self.maxPendingWriteBytes {
            // Helper is not draining stdin — treat as hung and disconnect so
            // the main actor is never coupled to a wedged child process.
            writeBroken = true
            writeLock.unlock()
            if !expectedExit {
                onWriteFailure()
            }
            return
        }
        pendingWriteBytes += line.count
        writeLock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.inputPipe.fileHandleForWriting.write(contentsOf: line)
                self.writeLock.lock()
                self.pendingWriteBytes -= line.count
                self.writeLock.unlock()
            } catch {
                self.writeLock.lock()
                let alreadyBroken = self.writeBroken
                self.writeBroken = true
                self.writeLock.unlock()
                if !alreadyBroken, !self.expectedExit {
                    self.onWriteFailure()
                }
            }
        }
    }

    func shutdown() {
        expectedExit = true
        try? send(IsolatedToolEnvelope(toolKind: kind, instanceID: instanceID, type: "shutdown"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()
        }
    }

    private func readAvailableOutput(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        outputBuffer.append(data)
        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            if let envelope = try? JSONDecoder().decode(IsolatedToolEnvelope.self, from: Data(line))
            {
                onEvent(envelope)
            }
        }
    }
}
