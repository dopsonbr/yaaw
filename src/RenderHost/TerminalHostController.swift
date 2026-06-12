import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import YAAWKit
import YAAWRenderProtocol

/// Hosts a real agent PTY terminal out-of-process.
///
/// `forkpty` runs through ``AgentTerminalProcess``; its output is tee'd to the
/// capture-log writer and to the Ghostty `InMemoryTerminalSession` through the
/// throttled ``AgentTerminalOutputPump`` behind a lossless
/// ``TerminalBackpressureGate``. The surface renders into a `CAMetalLayer`
/// inside a headless, off-screen window; that layer is wrapped in a
/// ``RemoteLayerContext`` and its `contextID` published to the app, which hosts
/// it with `CALayerHost` (ADR-004). Surface delegate events are forwarded to the
/// app via ``HelperTerminalDelegate``; capture-buffer overflow surfaces as
/// ``RenderEvent/captureTruncated(truncatedAtByte:)``.
@MainActor
final class TerminalHostController {
    private let view: TerminalView
    private let window: HeadlessTerminalWindow
    private let state: TerminalViewState
    private let pipeline: TerminalPTYPipeline
    // Ghostty's `view.delegate` is `weak`; the controller holds the only strong
    // reference (no cycle — the forwarder does not retain the controller).
    private let eventForwarder: HelperTerminalDelegate
    private let reply: RenderEventReply

    private var frameGeneration: UInt64 = 0
    private var lastSurfaceSeed: UInt32 = .max
    private var lastSurfaceID = ObjectIdentifier(NSNull())
    // Pushes the current IOSurface to the app on a modest cadence so terminal
    // output / cursor blink reach the pane. (A future refinement is to drive this
    // from libghostty's onPostRender instead of a timer.)
    private var frameTimer: DispatchSourceTimer?

    private var driver: AgentTerminalProcessDriver { pipeline.driver }

    init(launch: LaunchPayload, reply: RenderEventReply) {
        self.reply = reply

        let configuration = TerminalHostRenderingConfiguration.make(for: launch.rendering)
        let pipeline = TerminalPTYPipeline(launch: launch, reply: reply)
        self.pipeline = pipeline

        let state = TerminalViewState(
            theme: configuration.terminalTheme,
            terminalConfiguration: configuration.terminalConfiguration
        )
        state.adopt(colorScheme: configuration.swiftUIColorScheme)
        self.state = state

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.appearance = NSAppearance(named: configuration.appKitAppearanceName)
        view.autoresizingMask = [.width, .height]
        self.view = view

        let eventForwarder = HelperTerminalDelegate(state: state, reply: reply)
        self.eventForwarder = eventForwarder
        view.delegate = eventForwarder

        let fontSize = Float(launch.terminalFontSize ?? FontSettings().terminalSize)
        let options = TerminalSurfaceOptions(
            backend: .inMemory(pipeline.session),
            fontSize: fontSize,
            workingDirectory: launch.workingDirectory,
            context: .window
        )
        state.configuration = options
        state.setTerminalConfiguration(configuration.terminalConfiguration)
        view.controller = state.controller
        view.configuration = options

        // A headless, off-screen, never-fronted window gives the surface a
        // window to attach to (Ghostty only renders while `window != nil`)
        // without any visible chrome or focus steal. We composite its layer
        // remotely instead of showing the window.
        let window = HeadlessTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: configuration.appKitAppearanceName)
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window

        // The window MUST be ordered in (Ghostty's display link only renders into
        // its IOSurface while the window is live; `orderOut` stops rendering). It
        // stays invisible by sitting below the desktop window level (the wallpaper
        // occludes it) and is never made key (no focus steal). With IOSurface
        // sharing the app displays the surface directly, so this window is never
        // seen — and unlike CAContext, it does not need to be composited on screen.
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.orderFrontRegardless()
        view.setSurfaceVisible(true)
        // self is now fully initialized — safe to capture. Publish the shared
        // IOSurface once the surface attaches (the layer/surface is nil at init).
        eventForwarder.onSurfaceAttached = { [weak self] in self?.publishFrame() }
        startFramePump()
        publishFrame()
    }

    /// Resizes the live PTY grid and refits the surface, then re-publishes the
    /// frame handshake so the app's `contentsScale` correction runs against the
    /// new pixel size (replicating the coordinator's `onPostRender` fix).
    func resize(_ payload: ResizePayload) {
        if payload.widthPixels > 0, payload.heightPixels > 0, payload.contentsScale > 0 {
            let pointWidth = CGFloat(payload.widthPixels) / CGFloat(payload.contentsScale)
            let pointHeight = CGFloat(payload.heightPixels) / CGFloat(payload.contentsScale)
            let frame = NSRect(x: 0, y: 0, width: max(1, pointWidth), height: max(1, pointHeight))
            window.setFrame(frame, display: false, animate: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
        }
        applyContentsScale(payload.contentsScale)
        driver.resizeOrStart(
            to: AgentTerminalViewport(
                columns: payload.columns,
                rows: payload.rows,
                widthPixels: payload.widthPixels,
                heightPixels: payload.heightPixels
            )
        )
        view.fitToSize()
        publishFrame()
    }

    /// Writes raw input bytes (keyboard / paste / host-injected) to the PTY.
    func sendInput(_ data: Data) {
        driver.write(data)
    }

    /// Applies a theme/font/ligature change to the live surface without
    /// restarting the hosted process (hot-reload). Going through the state
    /// mutators only is deliberate: touching `state.configuration` /
    /// `view.configuration` would rebuild the surface and wipe the grid.
    func applyRendering(_ payload: RenderingPayload) {
        let configuration = TerminalHostRenderingConfiguration.make(for: payload.rendering)
        state.setTheme(configuration.terminalTheme)
        state.setTerminalConfiguration(configuration.terminalConfiguration)
        state.adopt(colorScheme: configuration.swiftUIColorScheme)
        view.appearance = NSAppearance(named: configuration.appKitAppearanceName)
        window.appearance = NSAppearance(named: configuration.appKitAppearanceName)
        view.fitToSize()
        publishFrame()
    }

    func terminate() {
        frameTimer?.cancel()
        frameTimer = nil
        driver.terminate()
        view.setSurfaceVisible(false)
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: - Compositing (shared IOSurface — ADR-004 Candidate 2)

    /// Reads the IOSurface backing the rendered surface and, when it has changed
    /// (new surface object or advanced seed), shares it with the app over XPC.
    /// The app sets it as its pane layer's `contents`.
    private func publishFrame() {
        guard let surface = currentSurface() else { return }
        let id = ObjectIdentifier(surface)
        let seed = IOSurfaceGetSeed(surface)
        guard id != lastSurfaceID || seed != lastSurfaceSeed else { return }
        lastSurfaceID = id
        lastSurfaceSeed = seed
        reply.frameReady(generation: nextGeneration(), surface: surface)
    }

    /// The IOSurface libghostty rendered into. The view's backing layer is an
    /// `IOSurfaceLayer`; its surface is exposed via `contents` (auto-bridged or a
    /// raw `IOSurfaceRef`) — fall back to KVC keys if a future layer hides it.
    private func currentSurface() -> IOSurface? {
        guard let contents = view.layer?.contents else { return nil }
        if let surface = contents as? IOSurface { return surface }
        let cf = contents as CFTypeRef
        if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
            return (cf as! IOSurface)
        }
        for key in ["surface", "ioSurface", "contents"] {
            guard let value = view.layer?.value(forKey: key) else { continue }
            let valueCF = value as CFTypeRef
            if CFGetTypeID(valueCF) == IOSurfaceGetTypeID() {
                return (valueCF as! IOSurface)
            }
        }
        return nil
    }

    /// Polls the surface on a modest cadence so ongoing terminal output reaches
    /// the pane (publishFrame is a no-op when the surface seed is unchanged).
    private func startFramePump() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.publishFrame() }
        }
        timer.resume()
        frameTimer = timer
    }

    /// Replicates the coordinator's scale correction: enforce `contentsScale` on
    /// the backing layer so the shared surface is sampled at the right density.
    private func applyContentsScale(_ contentsScale: Double) {
        guard contentsScale > 0, let layer = view.layer else { return }
        layer.contentsScale = CGFloat(contentsScale)
    }

    private func nextGeneration() -> UInt64 {
        frameGeneration &+= 1
        return frameGeneration
    }
}

/// The PTY-side pipeline of a terminal surface: the lossless backpressure gate,
/// the 32 KB output pump, the `forkpty` process, the serialized driver, the
/// optional capture-log writer, and the Ghostty in-memory session they feed.
///
/// Factored out of ``TerminalHostController`` so the controller's initializer
/// stays an assembly step rather than one large wiring block. All KEEP-verbatim
/// primitives (gate / process / pump / capture writer) are constructed here
/// unchanged from YAAWKit.
@MainActor
private struct TerminalPTYPipeline {
    let session: InMemoryTerminalSession
    let gate: TerminalBackpressureGate
    let pump: AgentTerminalOutputPump
    let process: AgentTerminalProcess
    let driver: AgentTerminalProcessDriver
    let captureWriter: AgentTerminalCaptureWriter?

    init(launch: LaunchPayload, reply: RenderEventReply) {
        let captureWriter = Self.makeCaptureWriter(launch: launch, reply: reply)
        self.captureWriter = captureWriter

        let callbacks = TerminalDriverCallbacks()
        let session = InMemoryTerminalSession(
            write: { data in callbacks.write(data) },
            resize: { viewport in callbacks.resize(viewport) }
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

        let process = AgentTerminalProcess(
            command: launch.command.isEmpty ? ["/bin/zsh", "-il"] : launch.command,
            workingDirectory: URL(fileURLWithPath: launch.workingDirectory),
            environment: Self.resolvedEnvironment(launch.environment),
            backpressureGate: gate,
            output: { data in
                captureWriter?.append(data)
                pump.enqueueOutput(data)
            },
            onExit: { exitCode in
                // Authoritative process-exit signal (forkpty child reaped).
                Task { @MainActor in reply.send(.exited(exitCode)) }
            }
        )
        self.process = process

        let driver = AgentTerminalProcessDriver(
            process: process,
            startupInput: launch.startupInput,
            onLaunchFailure: { error in
                pump.enqueueOutput(
                    Data("\r\nYAAW: failed to launch agent terminal: \(error)\r\n".utf8))
                Task { @MainActor in reply.send(.exited(127)) }
            }
        )
        self.driver = driver
        callbacks.driver = driver
    }

    /// An empty environment means "inherit" (plain exec terminals — bottom
    /// shell / nvim / lazygit); agent PTY launches carry their full env. Always
    /// ensures a `TERM` is set for the PTY.
    private static func resolvedEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        var resolved = environment.isEmpty ? ProcessInfo.processInfo.environment : environment
        if resolved["TERM"] == nil {
            resolved["TERM"] = "xterm-256color"
        }
        return resolved
    }

    private static func makeCaptureWriter(
        launch: LaunchPayload,
        reply: RenderEventReply
    ) -> AgentTerminalCaptureWriter? {
        launch.captureLogPath.map { path in
            AgentTerminalCaptureWriter(
                url: URL(fileURLWithPath: path),
                maximumBytes: launch.captureLogMaximumBytes.map(UInt64.init)
                    ?? AgentTerminalCaptureLog.maximumBytes,
                onTruncated: { truncatedAtByte in
                    Task { @MainActor in
                        reply.send(.captureTruncated(truncatedAtByte: truncatedAtByte))
                    }
                }
            )
        }
    }
}

/// Breaks the chicken-and-egg between the Ghostty session (needs write/resize
/// closures at init) and the driver (created afterwards).
private final class TerminalDriverCallbacks: @unchecked Sendable {
    var driver: AgentTerminalProcessDriver?

    func write(_ data: Data) {
        driver?.write(data)
    }

    func resize(_ viewport: InMemoryTerminalViewport) {
        driver?.resizeOrStart(
            to: AgentTerminalViewport(
                columns: UInt32(viewport.columns),
                rows: UInt32(viewport.rows),
                widthPixels: viewport.widthPixels,
                heightPixels: viewport.heightPixels
            )
        )
    }
}

/// A borderless, off-screen window that can still become key/main, so the
/// hosted surface can be first responder for input even though the window is
/// never ordered in. It hosts the surface only to give Ghostty a window to
/// attach to and a backing layer to render into; compositing is remote.
private final class HeadlessTerminalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension LaunchPayload {
    /// The rendering-only subset of this launch (theme/font/ligatures).
    fileprivate var rendering: IsolatedTerminalRendering {
        IsolatedTerminalRendering(
            themeID: themeID,
            terminalFontFamily: terminalFontFamily,
            terminalFontSize: terminalFontSize,
            terminalFontLigatures: terminalFontLigatures,
            appShortcutSignatures: appShortcutSignatures
        )
    }
}

extension RenderingPayload {
    /// This payload as the shared ``IsolatedTerminalRendering`` value.
    fileprivate var rendering: IsolatedTerminalRendering {
        IsolatedTerminalRendering(
            themeID: themeID,
            terminalFontFamily: terminalFontFamily,
            terminalFontSize: terminalFontSize,
            terminalFontLigatures: terminalFontLigatures,
            appShortcutSignatures: appShortcutSignatures
        )
    }
}
