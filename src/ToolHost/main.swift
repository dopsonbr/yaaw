import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import SwiftUI
import WebKit
import YAAWKit
import YAAWToolHostSupport

@MainActor
final class ToolHostApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    /// Headless e2e mode (inherited from the parent app's environment): the
    /// helper must never activate itself or raise its windows above other
    /// apps' work; it orders itself just above the parent app window instead.
    private let isHeadlessE2E =
        ProcessInfo.processInfo.environment["YAAW_E2E_HEADLESS"] == "1"

    private let decoder = JSONDecoder()
    private let cliToolKind: IsolatedToolKind
    private let cliInstanceID: String
    private var window: NSWindow?
    private var parentWindowNumber = 0
    private var webView: WKWebView?
    private var terminalController: TerminalHostController?
    private var terminalView: TerminalView? { terminalController?.view }
    private var terminalMouseDownMonitor: Any?
    private var terminalKeyboardShortcutMonitor: Any?
    private var terminalAppShortcutSignatures: Set<String> = []
    private var currentURLString: String?
    private var hasLaunchedTool = false
    private var isLoadingMarkdownPreview = false
    private var isSurfaceVisible = false
    private var shouldFloatSurface = true
    private var visibleLeaseDeadline: Date?
    private var watchdogTimer: Timer?

    init(toolKind: IsolatedToolKind, instanceID: String) {
        self.cliToolKind = toolKind
        self.cliInstanceID = instanceID
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startWatchdog()
        startInputReader()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminalController?.terminate()
        if let terminalMouseDownMonitor {
            NSEvent.removeMonitor(terminalMouseDownMonitor)
            self.terminalMouseDownMonitor = nil
        }
        if let terminalKeyboardShortcutMonitor {
            NSEvent.removeMonitor(terminalKeyboardShortcutMonitor)
            self.terminalKeyboardShortcutMonitor = nil
        }
    }

    private func startInputReader() {
        Thread.detachNewThread { [weak self] in
            while let line = readLine() {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                Task { @MainActor in
                    self?.handleLine(line)
                }
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func handleLine(_ line: String) {
        do {
            let data = Data(line.utf8)
            let envelope = try decoder.decode(IsolatedToolEnvelope.self, from: data).validated()
            guard envelope.toolKind == cliToolKind, envelope.instanceID == cliInstanceID else {
                send(
                    type: "error",
                    payload: [
                        "message": "Tool host received a command for the wrong tool instance."
                    ])
                return
            }
            handle(envelope)
        } catch {
            send(type: "error", payload: ["message": "Malformed tool host command: \(error)"])
        }
    }

    private func handle(_ envelope: IsolatedToolEnvelope) {
        switch envelope.type {
        case "launchTool":
            launchTool()
        case "launchTerminal":
            launchTerminal(payload: envelope.payload)
        case "setViewport":
            setViewport(payload: envelope.payload)
        case "show":
            setSurfaceVisible(true)
        case "hide":
            setSurfaceVisible(false)
        case "focus":
            if isHeadlessE2E {
                window?.makeKey()
                orderSurfaceFront()
            } else {
                if terminalView != nil {
                    NSApp.activate(ignoringOtherApps: true)
                    shouldFloatSurface = true
                    updateTerminalWindowLevel()
                }
                window?.makeKeyAndOrderFront(nil)
            }
            if let terminalView {
                window?.makeFirstResponder(terminalView)
            }
        case "blur":
            break
        case "input":
            sendTerminalInput(payload: envelope.payload)
        case "resize":
            terminalView?.fitToSize()
        case "terminate":
            terminalController?.terminate()
        case "setRenderingConfiguration":
            setRenderingConfiguration(payload: envelope.payload)
        case "load":
            load(urlString: envelope.payload["urlString"])
        case "goBack":
            webView?.goBack()
        case "goForward":
            webView?.goForward()
        case "reload":
            reload()
        case "stop":
            webView?.stopLoading()
            publishState()
        case "shutdown":
            NSApp.terminate(nil)
        case "crashForTesting":
            Darwin.exit(88)
        default:
            send(
                type: "error",
                payload: ["message": "Unsupported tool host command: \(envelope.type)"])
        }
    }

    private func launchTool() {
        guard !hasLaunchedTool else {
            send(type: "ready")
            return
        }
        hasLaunchedTool = true
        switch cliToolKind {
        case .browser:
            createBrowserWindow()
            send(type: "ready")
        case .terminal:
            // Implemented in Step 2 (TerminalHostController). Report rather than
            // silently no-op so the parent surfaces a clear failure state.
            send(type: "error", payload: ["message": "Terminal host is not implemented yet."])
        }
    }

    // MARK: - Terminal hosting

    private func launchTerminal(payload: [String: String]) {
        guard !hasLaunchedTool else {
            send(type: "ready")
            return
        }
        guard let launch = IsolatedTerminalLaunch.from(payload: payload) else {
            send(type: "error", payload: ["message": "Terminal host received an invalid launch."])
            return
        }
        hasLaunchedTool = true
        terminalAppShortcutSignatures = Set(launch.appShortcutSignatures)

        let controller = TerminalHostController(launch: launch) {
            [cliToolKind, cliInstanceID] type, payload in
            writeToolHostEnvelope(
                IsolatedToolEnvelope(
                    toolKind: cliToolKind, instanceID: cliInstanceID, type: type, payload: payload))
        }
        terminalController = controller

        // Borderless NSWindows return canBecomeKey=false by default, which would
        // prevent the ghostty surface from ever becoming first responder. Use a
        // subclass that can become key so keyboard input routes to the terminal.
        let window = TerminalHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.title = cliInstanceID
        let appearance = NSAppearance(named: controller.appKitAppearanceName)
        window.appearance = appearance
        controller.view.appearance = appearance
        controller.view.autoresizingMask = [.width, .height]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderOut(nil)
        controller.view.setSurfaceVisible(false)
        self.window = window
        installTerminalFocusMonitor()
        installTerminalKeyboardShortcutMonitor()

        send(type: "ready")
    }

    private func sendTerminalInput(payload: [String: String]) {
        guard let base64 = payload["bytes"],
            let data = Data(base64Encoded: base64)
        else { return }
        terminalController?.sendInput(data)
    }

    /// Applies a rendering-only update (theme, fonts, shortcuts) to the live
    /// terminal. Silently ignored before `launchTerminal`: stdin ordering
    /// guarantees the launch arrives first, and an "error" reply would flip
    /// the parent's phase to failed over a cosmetic update.
    private func setRenderingConfiguration(payload: [String: String]) {
        guard let terminalController else { return }
        let rendering = IsolatedTerminalRendering.from(payload: payload)
        terminalAppShortcutSignatures = Set(rendering.appShortcutSignatures)
        let configuration = TerminalHostRenderingConfiguration.make(for: rendering)
        terminalController.applyRenderingConfiguration(configuration)
        window?.appearance = NSAppearance(named: configuration.appKitAppearanceName)
    }

    private func createBrowserWindow() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderOut(nil)
        self.window = window
    }

    private func setViewport(payload: [String: String]) {
        guard let window,
            let x = payload["x"].flatMap(Double.init),
            let y = payload["y"].flatMap(Double.init),
            let width = payload["width"].flatMap(Double.init),
            let height = payload["height"].flatMap(Double.init)
        else { return }

        window.setFrame(
            NSRect(x: x, y: y, width: max(1, width), height: max(1, height)),
            display: true,
            animate: false
        )
        parentWindowNumber = payload["parentWindowNumber"].flatMap(Int.init) ?? parentWindowNumber
        let visible = payload["visible"].flatMap(Bool.init) == true
        shouldFloatSurface = payload["shouldFloat"].flatMap(Bool.init) ?? shouldFloatSurface
        let levelChanged = updateTerminalWindowLevel()
        visibleLeaseDeadline = visible ? Date().addingTimeInterval(0.6) : nil
        setSurfaceVisible(visible)
        if visible, isSurfaceVisible {
            if isHeadlessE2E {
                // Re-assert ordering just above the parent window; the helper
                // never floats headless, so z-order is not self-correcting.
                orderSurfaceFront()
            } else if levelChanged, shouldFloatSurface {
                window.orderFrontRegardless()
            }
        }
        // Re-assert the grid size on every viewport tick, hidden or not. The
        // parent reports at least every 0.15s, so a surface whose size drifted
        // from the window (e.g. a resize the renderer dropped while occluded
        // or mid-level-change) self-heals on the next tick instead of leaving
        // a stale grid + PTY over a wider pane.
        terminalView?.fitToSize()
    }

    /// Orders the surface window in. Headless, it slots in directly above the
    /// parent app window in global z-order so it never covers the user's work;
    /// headed, floating surfaces order front regardless as before.
    private func orderSurfaceFront() {
        guard let window else { return }
        if isHeadlessE2E, parentWindowNumber != 0 {
            window.order(.above, relativeTo: parentWindowNumber)
        } else if shouldFloatSurface {
            window.orderFrontRegardless()
        } else {
            window.orderFront(nil)
        }
    }

    private func setSurfaceVisible(_ visible: Bool) {
        guard let window else { return }
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        if visible {
            orderSurfaceFront()
            if window.isKeyWindow, let terminalView {
                window.makeFirstResponder(terminalView)
            }
            terminalView?.setSurfaceVisible(true)
            terminalView?.fitToSize()
        } else {
            terminalView?.setSurfaceVisible(false)
            window.orderOut(nil)
        }
    }

    @discardableResult
    private func updateTerminalWindowLevel() -> Bool {
        guard cliToolKind == .terminal, let window else { return false }
        let desiredLevel: NSWindow.Level = shouldFloatSurface ? .floating : .normal
        guard window.level != desiredLevel else { return false }
        window.level = desiredLevel
        return true
    }

    private func installTerminalFocusMonitor() {
        guard terminalMouseDownMonitor == nil else { return }
        terminalMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            guard let self,
                let window,
                let terminalView,
                event.window === window
            else {
                return event
            }
            let point = terminalView.convert(event.locationInWindow, from: nil)
            if terminalView.bounds.contains(point) {
                if isHeadlessE2E {
                    window.makeKey()
                    orderSurfaceFront()
                } else {
                    window.makeKeyAndOrderFront(nil)
                }
                window.makeFirstResponder(terminalView)
            }
            return event
        }
    }

    private func installTerminalKeyboardShortcutMonitor() {
        guard terminalKeyboardShortcutMonitor == nil else { return }
        terminalKeyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self else { return event }

            if let key = event.yaawShortcutKey,
                event.yaawShortcutModifiers.contains(.command),
                let signature = KeyboardShortcutDefinition(
                    key: key,
                    modifiers: Array(event.yaawShortcutModifiers)
                ).signature,
                terminalAppShortcutSignatures.contains(signature) || signature == "command+q"
            {
                let modifiers = event.yaawShortcutModifiers.map(\.rawValue).sorted().joined(
                    separator: ",")
                send(type: "keyboardShortcut", payload: ["key": key, "modifiers": modifiers])
                return nil
            }

            return routeHeadlessKeyEventIfNeeded(event)
        }
    }

    /// Headless, the helper app is never active, so the window server does not
    /// route posted keyboard events through normal key-window dispatch. Local
    /// monitors still fire before dispatch, so deliver the event straight to
    /// the terminal view and swallow it (returning the event would drop it).
    private func routeHeadlessKeyEventIfNeeded(_ event: NSEvent) -> NSEvent? {
        guard isHeadlessE2E, !NSApp.isActive, let terminalView else { return event }
        if let eventWindow = event.window, eventWindow !== window { return event }
        if event.modifierFlags.contains(.command), terminalView.performKeyEquivalent(with: event) {
            return nil
        }
        terminalView.keyDown(with: event)
        return nil
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHostLease()
            }
        }
        watchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkHostLease() {
        if getppid() == 1 {
            NSApp.terminate(nil)
            return
        }
        if let visibleLeaseDeadline, Date() > visibleLeaseDeadline {
            self.visibleLeaseDeadline = nil
            setSurfaceVisible(false)
        }
    }

    private func load(urlString: String?) {
        guard let urlString, let url = URL(string: urlString), let webView else {
            send(type: "error", payload: ["message": "Browser could not parse this URL."])
            return
        }
        currentURLString = urlString
        if url.isFileURL {
            loadFileURL(url)
        } else {
            webView.load(URLRequest(url: url))
        }
        publishState()
    }

    private func loadFileURL(_ url: URL) {
        guard let webView else { return }
        if MarkdownPreviewRenderer.isMarkdownURL(url) {
            loadMarkdownFile(url)
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private func loadMarkdownFile(_ url: URL) {
        guard let webView else { return }
        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let html = MarkdownPreviewRenderer.renderHTML(markdown: markdown, sourceURL: url)
            currentURLString = url.absoluteString
            isLoadingMarkdownPreview = true
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        } catch {
            send(
                type: "error",
                payload: [
                    "message":
                        "Markdown preview could not read this file: \(error.localizedDescription)"
                ])
        }
    }

    private func reload() {
        if webView?.url != nil {
            webView?.reload()
        } else {
            load(urlString: currentURLString)
        }
        publishState()
    }

    private func publishState() {
        var payload: [String: String] = [:]
        payload["title"] = webView?.title ?? ""
        payload["urlString"] = webView?.url?.absoluteString ?? currentURLString ?? ""
        payload["isLoading"] = String(webView?.isLoading ?? false)
        payload["canGoBack"] = String(webView?.canGoBack ?? false)
        payload["canGoForward"] = String(webView?.canGoForward ?? false)
        send(type: "stateChanged", payload: payload)
    }

    private func send(type: String, payload: [String: String] = [:]) {
        writeToolHostEnvelope(
            IsolatedToolEnvelope(
                toolKind: cliToolKind,
                instanceID: cliInstanceID,
                type: type,
                payload: payload
            ))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        publishState()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
            MarkdownPreviewRenderer.isMarkdownURL(url),
            url.absoluteString != currentURLString
        {
            currentURLString = url.absoluteString
            loadMarkdownFile(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isLoadingMarkdownPreview {
            isLoadingMarkdownPreview = false
        } else {
            currentURLString = webView.url?.absoluteString ?? currentURLString
        }
        publishState()
        send(type: "titleChanged", payload: ["title": webView.title ?? ""])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoadingMarkdownPreview = false
        guard !Self.isCancelled(error) else {
            publishState()
            return
        }
        send(type: "error", payload: ["message": Self.message(for: error)])
        publishState()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoadingMarkdownPreview = false
        guard !Self.isCancelled(error) else {
            publishState()
            return
        }
        send(type: "error", payload: ["message": Self.message(for: error)])
        publishState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        send(
            type: "error",
            payload: [
                "message":
                    "WebKit stopped rendering this page. Press reload to start a fresh renderer."
            ])
        publishState()
        Darwin.exit(89)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
            let urlString = navigationAction.request.url?.absoluteString
        {
            send(type: "newSurfaceRequested", payload: ["urlString": urlString])
        }
        return nil
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == WKError.errorDomain {
            return "WebKit could not load this page: \(nsError.localizedDescription)"
        }
        return nsError.localizedDescription
    }

    private static func isCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

/// Serializes envelope writes to stdout so events emitted from background
/// threads (e.g. the PTY read queue) can't interleave and corrupt a JSON line.
private let toolHostStdoutLock = NSLock()

private func writeToolHostEnvelope(_ envelope: IsolatedToolEnvelope) {
    guard let data = try? JSONEncoder().encode(envelope) else { return }
    toolHostStdoutLock.lock()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    toolHostStdoutLock.unlock()
}

/// A borderless window that can still become key/main, so the hosted terminal
/// surface can become first responder and receive keyboard input.
private final class TerminalHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts a real agent PTY terminal out-of-process: forkpty via
/// AgentTerminalProcess, output tee'd to the capture-log writer and the ghostty
/// InMemoryTerminalSession through the throttled pump + lossless backpressure
/// gate. Surface delegate events (title, command finished, notifications, focus)
/// are forwarded to the parent over IPC.
@MainActor
private final class TerminalHostController {
    let view: TerminalView
    let appKitAppearanceName: NSAppearance.Name
    private let state: TerminalViewState
    private let session: InMemoryTerminalSession
    private let gate: TerminalBackpressureGate
    private let pump: AgentTerminalOutputPump
    private let process: AgentTerminalProcess
    private let driver: AgentTerminalProcessDriver
    private let captureWriter: AgentTerminalCaptureWriter?
    private let delegate: HelperTerminalDelegate

    init(
        launch: IsolatedTerminalLaunch,
        onEvent: @escaping @Sendable (String, [String: String]) -> Void
    ) {
        let command = launch.command.isEmpty ? ["/bin/zsh", "-il"] : launch.command
        let workingDirectory = URL(fileURLWithPath: launch.workingDirectory)

        // An empty environment means "inherit" (used for plain exec terminals
        // like the bottom shell / nvim / lazygit); agent PTY launches carry their
        // full environment. Ensure TERM is always set for the PTY.
        var environment =
            launch.environment.isEmpty
            ? ProcessInfo.processInfo.environment : launch.environment
        if environment["TERM"] == nil {
            environment["TERM"] = "xterm-256color"
        }

        captureWriter = launch.captureLogPath.map { path in
            AgentTerminalCaptureWriter(
                url: URL(fileURLWithPath: path),
                maximumBytes: launch.captureLogMaximumBytes.map(UInt64.init)
                    ?? AgentTerminalCaptureLog.maximumBytes
            )
        }

        let callbacks = TerminalDriverCallbacks()
        let session = InMemoryTerminalSession(
            write: { data in callbacks.write(data) },
            resize: { viewport in
                callbacks.resize(
                    AgentTerminalViewport(
                        columns: UInt32(viewport.columns),
                        rows: UInt32(viewport.rows),
                        widthPixels: viewport.widthPixels,
                        heightPixels: viewport.heightPixels
                    ))
            }
        )
        self.session = session

        let gate = TerminalBackpressureGate()
        self.gate = gate
        let pump = AgentTerminalOutputPump(
            receive: { data in session.receive(data) },
            finish: { exitCode, runtimeMilliseconds in
                session.finish(exitCode: exitCode, runtimeMilliseconds: runtimeMilliseconds)
            },
            onDelivered: { [gate] byteCount in gate.consumed(byteCount) }
        )
        self.pump = pump

        let captureWriter = self.captureWriter
        let process = AgentTerminalProcess(
            command: command,
            workingDirectory: workingDirectory,
            environment: environment,
            backpressureGate: gate,
            output: { data in
                captureWriter?.append(data)
                pump.enqueueOutput(data)
            },
            onExit: { exitCode in
                // Authoritative process-exit signal (forkpty child reaped).
                onEvent("exited", ["exitCode": exitCode.map(String.init) ?? ""])
            }
        )
        self.process = process

        let driver = AgentTerminalProcessDriver(
            process: process,
            startupInput: launch.startupInput,
            onLaunchFailure: { error in
                pump.enqueueOutput(
                    Data("\r\nYAAW: failed to launch agent terminal: \(error)\r\n".utf8))
                onEvent("exited", ["exitCode": "127"])
            }
        )
        self.driver = driver
        callbacks.driver = driver

        let fontSize = Float(launch.terminalFontSize ?? FontSettings().terminalSize)
        let renderingConfiguration = TerminalHostRenderingConfiguration.make(for: launch.rendering)
        appKitAppearanceName = renderingConfiguration.appKitAppearanceName

        let state = TerminalViewState(
            theme: renderingConfiguration.terminalTheme,
            terminalConfiguration: renderingConfiguration.terminalConfiguration
        )
        state.adopt(colorScheme: renderingConfiguration.swiftUIColorScheme)
        self.state = state
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.appearance = NSAppearance(named: renderingConfiguration.appKitAppearanceName)
        self.view = view
        let delegate = HelperTerminalDelegate(state: state, onEvent: onEvent)
        self.delegate = delegate
        view.delegate = delegate

        let options = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: fontSize,
            workingDirectory: launch.workingDirectory,
            context: .window
        )
        state.configuration = options
        state.setTerminalConfiguration(renderingConfiguration.terminalConfiguration)
        view.controller = state.controller
        view.configuration = options
    }

    /// Applies theme/font changes to the live surface without restarting the
    /// hosted process. The update must go through the state mutators only:
    /// touching `state.configuration`/`view.configuration` rebuilds the surface
    /// on a font-size change and wipes the grid. Ghostty reflows the grid via
    /// its cell-size action; `fitToSize` is a defensive no-op otherwise.
    func applyRenderingConfiguration(_ configuration: TerminalHostRenderingConfiguration) {
        state.setTheme(configuration.terminalTheme)
        state.setTerminalConfiguration(configuration.terminalConfiguration)
        state.adopt(colorScheme: configuration.swiftUIColorScheme)
        view.appearance = NSAppearance(named: configuration.appKitAppearanceName)
        view.fitToSize()
    }

    /// Programmatic input (paste / host-injected text) straight to the PTY.
    func sendInput(_ data: Data) {
        driver.write(data)
    }

    func terminate() {
        driver.terminate()
    }

}

/// Breaks the chicken-and-egg between the ghostty session (needs write/resize
/// closures) and the driver (created afterwards).
private final class TerminalDriverCallbacks: @unchecked Sendable {
    var driver: AgentTerminalProcessDriver?

    func write(_ data: Data) {
        driver?.write(data)
    }

    func resize(_ viewport: AgentTerminalViewport) {
        driver?.resizeOrStart(to: viewport)
    }
}

/// Forwards ghostty surface delegate callbacks to the TerminalViewState (so the
/// surface renders correctly) and emits the parent-facing IPC events.
@MainActor
private final class HelperTerminalDelegate:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate
{
    private let state: TerminalViewState
    private let onEvent: @Sendable (String, [String: String]) -> Void

    init(
        state: TerminalViewState,
        onEvent: @escaping @Sendable (String, [String: String]) -> Void
    ) {
        self.state = state
        self.onEvent = onEvent
    }

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
        onEvent("titleChanged", ["title": title])
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state.terminalDidChangeFocus(focused)
        onEvent("focusChanged", ["focused": String(focused)])
    }

    func terminalDidClose(processAlive: Bool) {
        state.terminalDidClose(processAlive: processAlive)
        onEvent("closed", ["processAlive": String(processAlive)])
    }

    func terminalDidRingBell() {
        state.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
        onEvent("desktopNotification", ["title": title, "body": body])
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state.terminalDidChangeWorkingDirectory(path)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        // Per-command completion (shell integration), not process exit — used for
        // activity tracking only; the parent derives activity from the capture log.
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
        var payload: [String: String] = [
            "durationNanos": String(durationNanos)
        ]
        if let exitCode {
            payload["exitCode"] = String(exitCode)
        }
        onEvent("commandFinished", payload)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }
}

private func argumentValue(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

BundledFontCatalog.registerBundledFonts(diagnosticRecorder: LoggerDiagnosticEventRecorder.shared)
let toolKind =
    argumentValue(after: "--tool-kind").flatMap(IsolatedToolKind.init(rawValue:)) ?? .browser
let instanceID = argumentValue(after: "--instance-id") ?? UUID().uuidString
let delegate = ToolHostApp(toolKind: toolKind, instanceID: instanceID)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
