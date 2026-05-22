import AppKit
import Combine
import Foundation
import YAAWKit

@MainActor
final class IsolatedToolRuntime: ObservableObject {
    @Published private(set) var snapshotsByInstanceID: [String: IsolatedToolRuntimeSnapshot] = [:]

    var onNewSurfaceRequested: ((String) -> Void)?

    private var hostsByInstanceID: [String: IsolatedToolHostProcess] = [:]
    private let helperURLProvider: @MainActor () -> URL?

    init(helperURLProvider: @escaping @MainActor () -> URL? = IsolatedToolRuntime.defaultHelperURL)
    {
        self.helperURLProvider = helperURLProvider
    }

    func snapshot(for instanceID: String) -> IsolatedToolRuntimeSnapshot {
        snapshotsByInstanceID[instanceID] ?? IsolatedToolRuntimeSnapshot()
    }

    func ensureLaunched(kind: IsolatedToolKind, instanceID: String) {
        if hostsByInstanceID[instanceID] != nil { return }
        guard let helperURL = helperURLProvider(),
            FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            apply(.crashed("Tool host executable is unavailable."), instanceID: instanceID)
            return
        }

        apply(.launch, instanceID: instanceID)
        let host = IsolatedToolHostProcess(
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
                    self?.handleExit(instanceID: instanceID, wasExpected: wasExpected)
                }
            }
        )
        hostsByInstanceID[instanceID] = host

        do {
            try host.start()
            send(type: "launchTool", kind: kind, instanceID: instanceID)
        } catch {
            hostsByInstanceID[instanceID] = nil
            apply(
                .crashed("Tool host failed to start: \(error.localizedDescription)"),
                instanceID: instanceID)
        }
    }

    func loadBrowser(instanceID: String, urlString: String) {
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

    func setViewport(instanceID: String, frame: CGRect, visible: Bool) {
        if visible {
            hideAll(except: instanceID)
        }
        let payload = [
            "x": String(Double(frame.origin.x)),
            "y": String(Double(frame.origin.y)),
            "width": String(Double(frame.size.width)),
            "height": String(Double(frame.size.height)),
            "visible": String(visible),
        ]
        send(type: "setViewport", kind: .browser, instanceID: instanceID, payload: payload)
    }

    func hide(instanceID: String) {
        send(type: "hide", kind: .browser, instanceID: instanceID)
    }

    func hideAll(except activeInstanceID: String? = nil) {
        for instanceID in hostsByInstanceID.keys
        where activeInstanceID.map({ instanceID != $0 }) ?? true {
            hide(instanceID: instanceID)
        }
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
        apply(.exited, instanceID: instanceID)
    }

    func shutdownAll(except activeInstanceID: String? = nil) {
        let inactiveIDs = hostsByInstanceID.keys.filter { instanceID in
            activeInstanceID.map { instanceID != $0 } ?? true
        }
        for instanceID in inactiveIDs {
            guard let host = hostsByInstanceID[instanceID] else { continue }
            host.shutdown()
            hostsByInstanceID[instanceID] = nil
            apply(.exited, instanceID: instanceID)
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
            case "error":
                apply(
                    .error(envelope.payload["message"] ?? "Tool host reported an error."),
                    instanceID: envelope.instanceID)
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

    private func handleExit(instanceID: String, wasExpected: Bool) {
        hostsByInstanceID[instanceID] = nil
        apply(
            wasExpected ? .exited : .crashed("Tool host exited unexpectedly."),
            instanceID: instanceID)
    }

    private func apply(_ action: IsolatedToolRuntimeAction, instanceID: String) {
        snapshotsByInstanceID[instanceID] = IsolatedToolRuntimeReducer.reduce(
            snapshot(for: instanceID),
            action: action
        )
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
    private let helperURL: URL
    private let kind: IsolatedToolKind
    private let instanceID: String
    private let onEvent: (IsolatedToolEnvelope) -> Void
    private let onExit: (Bool) -> Void
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var outputBuffer = Data()
    private var expectedExit = false

    init(
        helperURL: URL,
        kind: IsolatedToolKind,
        instanceID: String,
        onEvent: @escaping (IsolatedToolEnvelope) -> Void,
        onExit: @escaping (Bool) -> Void
    ) {
        self.helperURL = helperURL
        self.kind = kind
        self.instanceID = instanceID
        self.onEvent = onEvent
        self.onExit = onExit
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
        let data = try JSONEncoder().encode(envelope)
        var line = data
        line.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: line)
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
