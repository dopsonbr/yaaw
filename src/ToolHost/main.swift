import AppKit
import Darwin
import Foundation
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
    private var currentURLString: String?
    private var hasLaunchedTool = false
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
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
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
                send(type: "error", payload: ["message": "Tool host received a command for the wrong tool instance."])
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
        case "setViewport":
            setViewport(payload: envelope.payload)
        case "show":
            setSurfaceVisible(true)
        case "hide":
            setSurfaceVisible(false)
        case "focus":
            window?.makeKeyAndOrderFront(nil)
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
            send(type: "error", payload: ["message": "Unsupported tool host command: \(envelope.type)"])
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
        }
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
    }

    private func setSurfaceVisible(_ visible: Bool) {
        guard let window else { return }
        guard visible != isSurfaceVisible else { return }
        isSurfaceVisible = visible
        if visible {
            window.orderFrontRegardless()
        } else {
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
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        publishState()
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
        let payload = [
            "title": webView?.title ?? "",
            "urlString": webView?.url?.absoluteString ?? currentURLString ?? "",
            "isLoading": String(webView?.isLoading ?? false),
            "canGoBack": String(webView?.canGoBack ?? false),
            "canGoForward": String(webView?.canGoForward ?? false)
        ]
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURLString = webView.url?.absoluteString ?? currentURLString
        publishState()
        send(type: "titleChanged", payload: ["title": webView.title ?? ""])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isCancelled(error) else {
            publishState()
            return
        }
        send(type: "error", payload: ["message": Self.message(for: error)])
        publishState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isCancelled(error) else {
            publishState()
            return
        }
        send(type: "error", payload: ["message": Self.message(for: error)])
        publishState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        send(type: "error", payload: ["message": "WebKit stopped rendering this page. Press reload to start a fresh renderer."])
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
           let urlString = navigationAction.request.url?.absoluteString {
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

private func argumentValue(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

let toolKind = argumentValue(after: "--tool-kind").flatMap(IsolatedToolKind.init(rawValue:)) ?? .browser
let instanceID = argumentValue(after: "--instance-id") ?? UUID().uuidString
let delegate = ToolHostApp(toolKind: toolKind, instanceID: instanceID)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
