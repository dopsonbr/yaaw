import AppKit
import Foundation
import IOSurface
import YAAWRenderProtocol

/// Accepts the app's XPC connection and wires it to a ``RenderServiceExporter``.
///
/// The app vends its ``YAAWRenderReplyProtocol`` object as the connection's
/// remote interface; the exporter grabs `remoteObjectProxy` to push frames and
/// events back. One helper process hosts exactly one surface, so one accepted
/// connection drives one exporter for the lifetime of the process.
final class RenderServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: YAAWRenderServiceProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: YAAWRenderReplyProtocol.self)

        let exporter = RenderServiceExporter(connection: newConnection)
        newConnection.exportedObject = exporter
        // Tearing down the surface and exiting on disconnect is what makes a
        // helper crash recoverable from the app's side: the app's invalidation
        // handler reaps + relaunches, and a clean app teardown here releases the
        // PTY / Ghostty surface deterministically.
        newConnection.invalidationHandler = { [weak exporter] in
            Task { @MainActor in
                exporter?.handleDisconnect()
            }
        }
        newConnection.interruptionHandler = { [weak exporter] in
            Task { @MainActor in
                exporter?.handleDisconnect()
            }
        }
        newConnection.resume()
        return true
    }
}

/// Decodes ``RenderMessage`` envelopes from the app and dispatches them to the
/// terminal or browser controller for this surface, forwarding ``RenderEvent``s
/// (and frame-ready notifications) back over the reply proxy.
///
/// `NSXPCConnection` may dispatch `handleMessage` on a private queue, so the
/// body hops to the main actor — the Ghostty surface and WKWebView are both
/// main-thread-only. The `reply` block is called immediately so the app's
/// calling thread never blocks on the (possibly slow) surface work.
@MainActor
final class RenderServiceExporter: NSObject, YAAWRenderServiceProtocol {
    private let reply: RenderEventReply
    private var terminalController: TerminalHostController?
    private var browserController: BrowserHostController?

    nonisolated init(connection: NSXPCConnection) {
        self.reply = RenderEventReply(connection: connection)
        super.init()
    }

    nonisolated func handleMessage(
        _ messageData: Data,
        reply replyBlock: @escaping (NSXPCListenerEndpoint?) -> Void
    ) {
        // Unblock the caller before touching the surface; the reverse channel is
        // the app's pre-vended remote object, so no endpoint is handed back.
        replyBlock(nil)
        let message: RenderMessage
        do {
            message = try JSONDecoder().decode(RenderMessage.self, from: messageData)
        } catch {
            return
        }
        Task { @MainActor in
            self.dispatch(message)
        }
    }

    func handleDisconnect() {
        terminalController?.terminate()
        terminalController = nil
        browserController = nil
        // The helper is single-surface; once the app drops the connection there
        // is nothing left to host, so exit cleanly and let the app relaunch.
        NSApplication.shared.terminate(nil)
    }

    private func dispatch(_ message: RenderMessage) {
        switch message {
        case .launch(let payload):
            launch(payload)
        case .resize(let payload):
            terminalController?.resize(payload)
            browserController?.resize(payload)
        case .input(let payload):
            terminalController?.sendInput(payload.data)
            browserController?.handleInput(payload.data)
        case .setRendering(let payload):
            // Rendering hot-reload is terminal-only; the browser has no theme.
            terminalController?.applyRendering(payload)
        case .shutdown:
            handleDisconnect()
        }
    }

    private func launch(_ payload: LaunchPayload) {
        guard terminalController == nil, browserController == nil else { return }
        switch IsolatedToolKind(rawValue: payload.toolKind) {
        case .terminal:
            terminalController = TerminalHostController(launch: payload, reply: reply)
        case .browser:
            browserController = BrowserHostController(launch: payload, reply: reply)
        case nil:
            break
        }
    }
}

/// Thin adapter that encodes ``RenderEvent``s and pushes them (and frame-ready
/// notifications) to the app's reply proxy, centralizing the encode + proxy
/// lookup so the controllers stay protocol-agnostic.
///
/// Deliberately `@unchecked Sendable`: this is the documented Obj-C/XPC bridge
/// exception. It wraps a single `NSXPCConnection`; `remoteObjectProxy` and the
/// one-way proxy sends it vends are thread-safe by XPC contract, so events
/// emitted from the main actor (surface delegate) and from background callbacks
/// (PTY exit / capture truncation, which already hop to the main actor here)
/// can both reach the app without an isolation hop on the connection itself.
final class RenderEventReply: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Encodes and sends a single event to the app.
    func send(_ event: RenderEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        proxy?.eventReceived(data)
    }

    /// Notifies the app a new frame is ready to composite, sharing the rendered
    /// `IOSurface` natively over XPC (the app sets it as its pane's layer
    /// contents — ADR-004 Candidate 2).
    func frameReady(generation: UInt64, surface: IOSurface?) {
        proxy?.frameReady(generation: generation, surface: surface)
    }

    private var proxy: YAAWRenderReplyProtocol? {
        connection.remoteObjectProxy as? YAAWRenderReplyProtocol
    }
}
