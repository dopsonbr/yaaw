import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import WebKit
import YAAWKit

@MainActor
final class ToolHostApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cliToolKind: IsolatedToolKind
    private let cliInstanceID: String
    private var window: NSWindow?
    private var webView: WKWebView?
    private var terminalView: TerminalView?
    private var terminalState: TerminalViewState?
    private var currentURLString: String?
    private var hasLaunchedTool = false
    private var isLoadingMarkdownPreview = false
    private var isSurfaceVisible = false
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
            if terminalView != nil {
                NSApp.activate(ignoringOtherApps: true)
            }
            window?.makeKeyAndOrderFront(nil)
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
            NSApp.terminate(nil)
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

    // MARK: - Terminal hosting (spike)

    private func launchTerminal(payload: [String: String]) {
        guard !hasLaunchedTool else {
            send(type: "ready")
            return
        }
        hasLaunchedTool = true
        createTerminalWindow(launch: IsolatedTerminalLaunch.from(payload: payload))
        send(type: "ready")
    }

    private func createTerminalWindow(launch: IsolatedTerminalLaunch?) {
        let command = launch.map(\.command).flatMap { $0.isEmpty ? nil : $0 } ?? ["/bin/zsh", "-il"]
        let workingDirectory =
            launch?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

        var terminalConfiguration = TerminalConfiguration.default.fontSize(13)
        terminalConfiguration = terminalConfiguration.custom(
            "command", Self.shellCommandLine(for: command))

        let state = TerminalViewState(terminalConfiguration: terminalConfiguration)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.delegate = state

        let options = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 13,
            workingDirectory: workingDirectory,
            context: .window
        )
        state.configuration = options
        state.setTerminalConfiguration(terminalConfiguration)
        view.controller = state.controller
        view.configuration = options

        // Borderless NSWindows return canBecomeKey=false by default, which would
        // prevent the ghostty surface from ever becoming first responder. Use a
        // subclass that can become key so keyboard input routes to the terminal.
        let window = TerminalHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.autoresizingMask = [.width, .height]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderOut(nil)
        view.setSurfaceVisible(false)
        self.window = window
        self.terminalView = view
        self.terminalState = state
    }

    private func sendTerminalInput(payload: [String: String]) {
        guard let base64 = payload["bytes"],
            let data = Data(base64Encoded: base64),
            let text = String(data: data, encoding: .utf8),
            let terminalState
        else { return }
        _ = terminalState.send(text)
    }

    private static func shellCommandLine(for command: [String]) -> String {
        command.map { argument in
            if argument.rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'\\$`")))
                == nil
            {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
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
        let visible = payload["visible"].flatMap(Bool.init) == true
        visibleLeaseDeadline = visible ? Date().addingTimeInterval(0.6) : nil
        setSurfaceVisible(visible)
        // Reflow the terminal grid to the new pane size while it stays visible
        // (setSurfaceVisible only fits on a visibility transition).
        if visible, terminalView != nil {
            terminalView?.fitToSize()
        }
    }

    private func setSurfaceVisible(_ visible: Bool) {
        guard let window else { return }
        // Keep the surface visible while the user is interacting with this helper
        // window: clicking it makes it key, which deactivates the main app, which
        // makes the parent's viewport reporter report the pane as not-visible.
        // Hiding then would yank the terminal out from under the user.
        if !visible && window.isKeyWindow {
            return
        }
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        if visible {
            window.orderFrontRegardless()
            terminalView?.setSurfaceVisible(true)
            terminalView?.fitToSize()
        } else {
            terminalView?.setSurfaceVisible(false)
            window.orderOut(nil)
        }
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
        let envelope = IsolatedToolEnvelope(
            toolKind: cliToolKind,
            instanceID: cliInstanceID,
            type: type,
            payload: payload
        )
        guard let data = try? encoder.encode(envelope) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
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

/// A borderless window that can still become key/main, so the hosted terminal
/// surface can become first responder and receive keyboard input.
private final class TerminalHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private func argumentValue(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

let toolKind =
    argumentValue(after: "--tool-kind").flatMap(IsolatedToolKind.init(rawValue:)) ?? .browser
let instanceID = argumentValue(after: "--instance-id") ?? UUID().uuidString
let delegate = ToolHostApp(toolKind: toolKind, instanceID: instanceID)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
