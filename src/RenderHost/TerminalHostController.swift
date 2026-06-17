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
/// ``TerminalBackpressureGate``. The surface renders into libghostty's
/// `IOSurfaceLayer` inside a headless, off-screen window; the backing `IOSurface`
/// is shared with the app over XPC, which displays it as its pane layer's
/// `contents` (ADR-004 Candidate 2 — CAContext/`CALayerHost` was found not to
/// share cross-process). Surface delegate events are forwarded to the app via
/// ``HelperTerminalDelegate``; capture-buffer overflow surfaces as
/// ``RenderEvent/captureTruncated(truncatedAtByte:)``.
@MainActor
final class TerminalHostController {
    private let view: TerminalView
    private let window: HeadlessRenderWindow
    private let state: TerminalViewState
    private let pipeline: TerminalPTYPipeline
    // Ghostty's `view.delegate` is `weak`; the controller holds the only strong
    // reference (no cycle — the forwarder does not retain the controller).
    private let eventForwarder: HelperTerminalDelegate
    private let reply: RenderEventReply

    private var frameGeneration: UInt64 = 0
    private var lastSurfaceSeed: UInt32 = .max
    private var lastSurfaceID = ObjectIdentifier(NSNull())
    // Pushes the current IOSurface to the app when it actually changes. libghostty
    // renders into the shared surface on its own display link (which it pauses
    // when the terminal is idle); we poll the surface seed and forward only
    // changed frames. The cadence is adaptive — ~30 fps while frames keep
    // changing, dropping to ~5 fps after a short quiet period — so a static pane
    // costs almost no wakeups. A fully event-driven push would need libghostty's
    // private `onPostRender`, which libghostty-spm 1.2.4 does not vend publicly
    // (tracked in DEFERRED-ISSUES #21).
    private var frameTimer: DispatchSourceTimer?
    private var idleFrameTicks = 0
    private var currentFrameInterval: DispatchTimeInterval = TerminalHostController
        .activeFrameInterval
    private static let activeFrameInterval = DispatchTimeInterval.milliseconds(33)
    private static let idleFrameInterval = DispatchTimeInterval.milliseconds(200)
    /// Unchanged frames before dropping to the idle cadence (~0.6 s at 33 ms).
    private static let idleFrameThreshold = 18

    /// Replayed when the surface attaches so the PTY uses libghostty's real grid.
    private var lastResizePayload: ResizePayload?
    private var preciseScrollAccumulator = TerminalPreciseScrollAccumulator()

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

        // A headless, invisible window gives the surface a window to attach to
        // (Ghostty only renders while `window != nil`) without any visible chrome
        // or focus steal. We composite its layer remotely instead of showing it.
        let window = HeadlessRenderWindow(
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
        // stays invisible via `orderInHidden` (alpha 0, never key) rather than the
        // old below-the-wallpaper trick, which macOS 26 no longer hides. With
        // IOSurface sharing the app displays the surface directly, so this window
        // is never seen.
        orderInHidden(window)
        view.setSurfaceVisible(true)
        // The first resize can arrive before the IOSurface attaches; re-fit once it
        // exists so the PTY starts from libghostty's real cell grid.
        eventForwarder.onSurfaceAttached = { [weak self] in self?.handleSurfaceAttached() }
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
        lastResizePayload = payload
        // Prefer libghostty's fitted grid over the app's pre-attach estimate.
        view.fitToSize()
        let viewport = authoritativeViewport(fallback: payload)
        driver.resizeOrStart(to: viewport)
        publishFrame()
    }

    /// Re-fits and publishes once libghostty's IOSurface has attached.
    private func handleSurfaceAttached() {
        view.fitToSize()
        if let payload = lastResizePayload {
            let viewport = authoritativeViewport(fallback: payload)
            driver.resizeOrStart(to: viewport)
        }
        publishFrame()
    }

    /// The viewport to start/resize the PTY with: the surface's real fitted grid
    /// (from libghostty's cell metrics) when available, else the app's estimate.
    private func authoritativeViewport(fallback payload: ResizePayload) -> AgentTerminalViewport {
        if let metrics = state.surfaceSize, metrics.columns > 0, metrics.rows > 0 {
            return AgentTerminalViewport(
                columns: UInt32(metrics.columns),
                rows: UInt32(metrics.rows),
                widthPixels: metrics.widthPixels,
                heightPixels: metrics.heightPixels
            )
        }
        return AgentTerminalViewport(
            columns: payload.columns,
            rows: payload.rows,
            widthPixels: payload.widthPixels,
            heightPixels: payload.heightPixels
        )
    }

    /// Writes raw input bytes (keyboard / paste / host-injected) to the PTY.
    func sendInput(_ data: Data) {
        driver.write(data)
    }

    /// Forwards a mouse event from the app pane into the off-screen `TerminalView`.
    /// The view is never on screen so it gets no real mouse events; we reconstruct
    /// an `NSEvent` (or a `CGEvent`-backed scroll event) at the pane's top-left
    /// point and call the view's `open` mouse handlers, which feed libghostty's
    /// mouse API. libghostty emits the right SGR/X11 sequences per the terminal's
    /// current mouse mode, so nvim/lazygit/less/etc. receive mouse input.
    func handleMouse(_ payload: MousePayload) {
        let modifiers = NSEvent.ModifierFlags(rawValue: payload.modifierFlags)
        switch payload.action {
        case .scroll:
            guard dispatchScrollEvent(payload: payload) else { return }
        case .moved:
            guard let event = mouseEvent(type: .mouseMoved, payload: payload, modifiers: modifiers)
            else { return }
            view.mouseMoved(with: event)
        case .down, .up, .dragged:
            dispatchButtonEvent(payload: payload, modifiers: modifiers)
        }
        publishFrame()
    }

    private func dispatchScrollEvent(payload: MousePayload) -> Bool {
        var scrollPayload = payload
        if payload.hasPreciseScrolling {
            let delta = preciseScrollAccumulator.add(
                deltaX: payload.scrollDeltaX,
                deltaY: payload.scrollDeltaY)
            guard !delta.isZero else { return false }
            scrollPayload.scrollDeltaX = Double(delta.x)
            scrollPayload.scrollDeltaY = Double(delta.y)
        }
        guard let event = Self.scrollEvent(payload: scrollPayload) else { return false }
        view.scrollWheel(with: event)
        return true
    }

    private func dispatchButtonEvent(payload: MousePayload, modifiers: NSEvent.ModifierFlags) {
        // One switch maps (action, button) straight to the event type and the
        // view's matching `open` handler, so there is no second dispatch.
        let resolved: (type: NSEvent.EventType, handler: (NSEvent) -> Void)
        switch (payload.action, payload.button) {
        case (.down, .left): resolved = (.leftMouseDown, view.mouseDown(with:))
        case (.up, .left): resolved = (.leftMouseUp, view.mouseUp(with:))
        case (.dragged, .left): resolved = (.leftMouseDragged, view.mouseDragged(with:))
        case (.down, .right): resolved = (.rightMouseDown, view.rightMouseDown(with:))
        case (.up, .right): resolved = (.rightMouseUp, view.rightMouseUp(with:))
        case (.dragged, .right): resolved = (.rightMouseDragged, view.rightMouseDragged(with:))
        case (.down, .middle): resolved = (.otherMouseDown, view.otherMouseDown(with:))
        case (.up, .middle): resolved = (.otherMouseUp, view.otherMouseUp(with:))
        case (.dragged, .middle): resolved = (.otherMouseDragged, view.otherMouseDragged(with:))
        default: return
        }
        guard let event = mouseEvent(type: resolved.type, payload: payload, modifiers: modifiers)
        else { return }
        resolved.handler(event)
    }

    private func mouseEvent(
        type: NSEvent.EventType, payload: MousePayload, modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        // The pane sends a top-left point; the view's `mousePoint` flips with
        // `bounds.height`, so place the event at `locationInWindow = (x, H - y)`
        // (the view fills its window at the origin, so window-base == view coords).
        let location = NSPoint(x: payload.x, y: view.bounds.height - payload.y)
        let isUp = type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: isUp ? 0 : 1
        )
    }

    private static func scrollEvent(payload: MousePayload) -> NSEvent? {
        let precise = payload.hasPreciseScrolling
        let units: CGScrollEventUnit = precise ? .pixel : .line
        guard
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: units,
                wheelCount: 2,
                wheel1: Int32(payload.scrollDeltaY.rounded()),
                wheel2: Int32(payload.scrollDeltaX.rounded()),
                wheel3: 0)
        else { return nil }
        // Preserve small trackpad deltas that would round to zero in wheelN.
        if precise {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setDoubleValueField(
                .scrollWheelEventPointDeltaAxis1, value: payload.scrollDeltaY)
            cgEvent.setDoubleValueField(
                .scrollWheelEventPointDeltaAxis2, value: payload.scrollDeltaX)
        }
        return NSEvent(cgEvent: cgEvent)
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
    /// The app sets it as its pane layer's `contents`. Returns whether a frame was
    /// actually pushed (drives the adaptive pump cadence).
    @discardableResult
    private func publishFrame() -> Bool {
        guard let surface = currentSurface() else { return false }
        let id = ObjectIdentifier(surface)
        let seed = IOSurfaceGetSeed(surface)
        guard id != lastSurfaceID || seed != lastSurfaceSeed else { return false }
        lastSurfaceID = id
        lastSurfaceSeed = seed
        reply.frameReady(generation: nextGeneration(), surface: surface)
        return true
    }

    /// The IOSurface libghostty rendered into. The view's backing layer is an
    /// `IOSurfaceLayer`; its surface is exposed via `contents` (auto-bridged or a
    /// raw `IOSurfaceRef`) — fall back to KVC keys if a future layer hides it.
    private func currentSurface() -> IOSurface? {
        guard let layer = view.layer else { return nil }
        if let surface = Self.ioSurface(from: layer.contents) { return surface }
        for key in ["surface", "ioSurface", "contents"] {
            if let surface = Self.ioSurface(from: layer.value(forKey: key)) { return surface }
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = Self.currentSurface(in: sublayer) { return surface }
        }
        return nil
    }

    private static func currentSurface(in layer: CALayer) -> IOSurface? {
        if let surface = ioSurface(from: layer.contents) { return surface }
        for key in ["surface", "ioSurface", "contents"] {
            if let surface = ioSurface(from: layer.value(forKey: key)) { return surface }
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = currentSurface(in: sublayer) { return surface }
        }
        return nil
    }

    private static func ioSurface(from value: Any?) -> IOSurface? {
        guard let value else { return nil }
        if let surface = value as? IOSurface { return surface }
        let cf = value as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return nil }
        return (cf as! IOSurface)
    }

    /// Polls the surface so ongoing terminal output reaches the pane (publishFrame
    /// is a no-op when the surface seed is unchanged), adapting the cadence down
    /// to the idle rate after a quiet period and back up on the next changed frame.
    private func startFramePump() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.adaptFrameCadence(pushed: self.publishFrame())
            }
        }
        timer.schedule(deadline: .now() + 0.1, repeating: Self.activeFrameInterval)
        timer.resume()
        currentFrameInterval = Self.activeFrameInterval
        frameTimer = timer
    }

    /// Speeds the pump back to the active rate on a new frame; slows it to the
    /// idle rate after `idleFrameThreshold` consecutive unchanged ticks.
    private func adaptFrameCadence(pushed: Bool) {
        if pushed {
            idleFrameTicks = 0
            setFrameInterval(Self.activeFrameInterval)
        } else {
            idleFrameTicks += 1
            if idleFrameTicks >= Self.idleFrameThreshold {
                setFrameInterval(Self.idleFrameInterval)
            }
        }
    }

    private func setFrameInterval(_ interval: DispatchTimeInterval) {
        guard interval != currentFrameInterval, let frameTimer else { return }
        currentFrameInterval = interval
        frameTimer.schedule(deadline: .now() + interval, repeating: interval)
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
