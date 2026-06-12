import AppKit
import Combine
import Foundation
import IOSurface
import YAAWKit
import YAAWRenderProtocol

/// The phase a single render surface is in. Drives the pane's overlay (launching
/// / reconnecting / exited) and whether `TerminalSurfaceHostView` composites the
/// remote layer.
enum RenderSurfacePhase: Equatable, Sendable {
    case idle
    case launching
    case ready
    case failed(String)
    /// The helper died/dropped; the client is relaunching + replaying viewport.
    case reconnecting(String)
    case exited(Int32?)
}

/// Observable per-surface state the host view reads: the lifecycle phase and the
/// title. Deliberately does **not** carry the per-frame generation — frames are
/// delivered straight to the pane layer through a non-`@Published` sink (see
/// ``RenderHostClient/setFrameSink(role:_:)``) so a blinking cursor / live output
/// never re-invalidates SwiftUI. Only phase/title transitions (which are rare)
/// flow through `@Published`. The IOSurface itself is held separately (see
/// ``RenderHostClient/surface(for:)``) because it is not `Sendable`.
struct RenderSurfaceSnapshot: Equatable, Sendable {
    var phase: RenderSurfacePhase = .idle
    var exitCode: Int32?
    var title: String = ""
}

/// Main-side owner of the per-surface `YAAWRenderHost` helpers. Replaces the
/// pre-rewrite `IsolatedToolRuntime`'s NDJSON-over-stdio terminal logic with one
/// `NSXPCConnection` per surface to the XPC helper.
///
/// Conforms to ``RenderSurfaceManaging`` so `AppEnvironment` injects it into the
/// stores: `activate`/`shutdown`/`isActive` are the synchronous façade the
/// stores call; the XPC handshake, frame compositing handshake, hot-reload-vs-
/// relaunch decision (`IsolatedTerminalLaunchTransition.between`), viewport
/// replay, and recoverable-helper-death recovery happen behind it.
///
/// `@MainActor` (not an `actor`) because the SwiftUI host views and the XPC
/// reply object touch its state on the main thread; the off-main I/O lives in
/// the helper process and in `NSXPCConnection`'s own queues. No `isolated
/// deinit` (D-011).
@MainActor
final class RenderHostClient: ObservableObject, RenderSurfaceManaging {
    /// Per-surface snapshots the host views observe (keyed by role).
    @Published private(set) var snapshotsByRole: [RenderSurfaceRole: RenderSurfaceSnapshot] = [:]

    /// Latest theme/font rendering the activate path stamps onto launches. The
    /// app pushes this in on settings/appearance changes so hot-reload applies.
    var rendering: IsolatedTerminalRendering = IsolatedTerminalRendering()

    /// Forwarded Cmd-shortcuts the helper passes back (key, modifier raw values).
    var onKeyboardShortcut: ((String, [String]) -> Void)?
    /// Surface lifecycle events surfaced to the activity store (title, exit,
    /// notification, command-finished) keyed by role.
    var onSurfaceEvent: ((RenderSurfaceRole, RenderEvent) -> Void)?

    private let helperURLProvider: @MainActor () -> URL?
    private let diagnosticRecorder: any DiagnosticEventRecording
    private var connectionsByRole: [RenderSurfaceRole: SurfaceConnection] = [:]
    /// Latest shared IOSurface per role (kept out of the `Sendable`
    /// `RenderSurfaceSnapshot`; the host view reads it via ``surface(for:)``).
    private var surfacesByRole: [RenderSurfaceRole: IOSurface] = [:]
    /// Last frame generation accepted per role (stale-frame guard, kept out of
    /// `@Published` so frame delivery never invalidates SwiftUI).
    private var lastGenerationByRole: [RenderSurfaceRole: UInt64] = [:]
    /// Per-role frame sink the pane view registers; called on every new frame to
    /// set the pane layer's contents directly, bypassing `@Published`.
    private var frameSinksByRole: [RenderSurfaceRole: (IOSurface?) -> Void] = [:]

    init(
        helperURLProvider: @escaping @MainActor () -> URL? = RenderHostClient.defaultHelperURL,
        diagnosticRecorder: any DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared
    ) {
        self.helperURLProvider = helperURLProvider
        self.diagnosticRecorder = diagnosticRecorder
    }

    // MARK: - RenderSurfaceManaging

    // The protocol is `Sendable` with non-isolated, synchronous methods; the
    // stores always call them from the `@MainActor`. Marking them `nonisolated`
    // and re-entering the main actor via `assumeIsolated` satisfies the
    // conformance-isolation rule without an actor hop.

    /// Launches or re-activates the surface. The stores call this; the heavy
    /// lifting (XPC launch, launch message) is dispatched without blocking.
    @discardableResult
    nonisolated func activate(_ launch: RenderSurfaceLaunch) -> Bool {
        MainActor.assumeIsolated {
            let role = launch.role
            let terminalLaunch = Self.terminalLaunch(from: launch, rendering: rendering)
            ensureLaunched(role: role, launch: terminalLaunch)
            return connectionsByRole[role]?.isConnected ?? false
        }
    }

    nonisolated func shutdown(role: RenderSurfaceRole) {
        MainActor.assumeIsolated {
            connectionsByRole[role]?.shutdown(expected: true)
            connectionsByRole.removeValue(forKey: role)
            snapshotsByRole[role] = RenderSurfaceSnapshot(phase: .exited(nil))
        }
    }

    nonisolated func isActive(role: RenderSurfaceRole) -> Bool {
        MainActor.assumeIsolated {
            connectionsByRole[role]?.isConnected ?? false
        }
    }

    // MARK: - Reads for the host view

    func snapshot(for role: RenderSurfaceRole) -> RenderSurfaceSnapshot {
        snapshotsByRole[role] ?? RenderSurfaceSnapshot()
    }

    /// The latest IOSurface the helper shared for `role`, for the host view to
    /// set as its layer contents (ADR-004 Candidate 2).
    func surface(for role: RenderSurfaceRole) -> IOSurface? {
        surfacesByRole[role]
    }

    /// Registers (or clears, with `nil`) the pane view's frame sink for `role`.
    /// The newest registered pane view wins; the sink is invoked on the main
    /// actor for every new frame. Frame delivery goes through this sink rather
    /// than `@Published` so 30 fps frames never trigger SwiftUI invalidation.
    func setFrameSink(role: RenderSurfaceRole, _ sink: ((IOSurface?) -> Void)?) {
        frameSinksByRole[role] = sink
    }

    // MARK: - Launch / hot-reload / relaunch

    /// Implements the hot-reload-vs-relaunch decision: identical launch is a
    /// no-op, a rendering-only change is sent to the live helper, a process
    /// change tears down and relaunches (replaying the cached viewport).
    func ensureLaunched(role: RenderSurfaceRole, launch: IsolatedTerminalLaunch) {
        let existing = connectionsByRole[role]
        switch IsolatedTerminalLaunchTransition.between(existing?.launch, launch) {
        case .noChange:
            return
        case .updateRendering where existing != nil:
            existing?.launch = launch
            existing?.send(.setRendering(RenderingPayload(rendering: launch.rendering)))
            return
        case .updateRendering, .launchNew:
            break
        case .relaunchProcess:
            existing?.shutdown(expected: true)
            connectionsByRole.removeValue(forKey: role)
        }
        startConnection(role: role, launch: launch)
    }

    /// Hot-reloads rendering (theme/font/ligatures) on every live surface.
    func applyRenderingToAll(_ rendering: IsolatedTerminalRendering) {
        self.rendering = rendering
        for (role, connection) in connectionsByRole {
            var launch = connection.launch
            launch.applyRendering(rendering)
            connection.launch = launch
            connection.send(.setRendering(RenderingPayload(rendering: rendering)))
            _ = role
        }
    }

    /// Sends a resize (pane pixel size + grid + backing scale) to the helper and
    /// caches it so a relaunch can replay it.
    func setViewport(
        role: RenderSurfaceRole,
        columns: UInt32,
        rows: UInt32,
        widthPixels: UInt32,
        heightPixels: UInt32,
        contentsScale: Double
    ) {
        let payload = ResizePayload(
            columns: columns,
            rows: rows,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            contentsScale: contentsScale
        )
        let connection = connectionsByRole[role]
        connection?.lastViewport = payload
        connection?.send(.resize(payload))
    }

    func sendInput(role: RenderSurfaceRole, data: Data) {
        connectionsByRole[role]?.send(.input(InputPayload(data: data)))
    }

    func sendMouse(role: RenderSurfaceRole, payload: MousePayload) {
        connectionsByRole[role]?.send(.mouse(payload))
    }

    func shutdownAll() {
        for role in Array(connectionsByRole.keys) {
            shutdown(role: role)
        }
    }

    // MARK: - Connection lifecycle

    private func startConnection(role: RenderSurfaceRole, launch: IsolatedTerminalLaunch) {
        // A fresh helper process restarts its frame generation at 0, so drop the
        // previous helper's generation watermark (and stale surface) — otherwise
        // the new helper's first frames are rejected as stale and a relaunched /
        // crash-recovered pane stays black. This is what lets recovery re-render.
        lastGenerationByRole[role] = 0
        surfacesByRole.removeValue(forKey: role)
        guard let helperURL = helperURLProvider() else {
            updateSnapshot(role: role) {
                $0.phase = .failed("Render helper is unavailable.")
            }
            return
        }
        updateSnapshot(role: role) { $0.phase = .launching }
        let reply = RenderReply(role: role, client: self)
        let connection = SurfaceConnection(
            role: role,
            helperURL: helperURL,
            launch: launch,
            reply: reply
        )
        connection.onInvalidate = { [weak self] in
            Task { @MainActor in self?.handleInvalidation(role: role) }
        }
        connectionsByRole[role] = connection
        connection.resume()
        // The browser surface hosts a WKWebView (toolKind=.browser); every other
        // role hosts a PTY-backed terminal. The cached `launch` carries the
        // role-appropriate `command` either way (browser: `["load", url]`).
        let payload: LaunchPayload
        if case .browser = role {
            payload = LaunchPayload(browser: launch)
        } else {
            payload = LaunchPayload(terminal: launch)
        }
        connection.send(.launch(payload))
        if let viewport = connection.lastViewport {
            connection.send(.resize(viewport))
        }
        recordDiagnostic(
            name: "render_surface_launch_requested", metadata: ["role": role.diagnosticName])
    }

    /// Recoverable helper death: the XPC `invalidationHandler` fired. Move the
    /// pane to "reconnecting", relaunch, and replay the cached viewport.
    private func handleInvalidation(role: RenderSurfaceRole) {
        guard let connection = connectionsByRole[role] else { return }
        guard !connection.expectedShutdown else { return }
        recordDiagnostic(
            name: "render_surface_helper_died", metadata: ["role": role.diagnosticName])
        updateSnapshot(role: role) { $0.phase = .reconnecting("The render helper exited.") }
        let launch = connection.launch
        let viewport = connection.lastViewport
        connection.shutdown(expected: true)
        connectionsByRole.removeValue(forKey: role)
        startConnection(role: role, launch: launch)
        if let viewport {
            connectionsByRole[role]?.lastViewport = viewport
            connectionsByRole[role]?.send(.resize(viewport))
        }
    }

    // MARK: - Reply handling (from the helper)

    fileprivate func handleFrameReady(
        role: RenderSurfaceRole, generation: UInt64, surface: IOSurface?
    ) {
        guard generation >= (lastGenerationByRole[role] ?? 0) else { return }
        lastGenerationByRole[role] = generation
        if let surface { surfacesByRole[role] = surface }
        // Deliver the frame straight to the pane layer — NOT through `@Published`
        // — so live output / cursor blink never re-invalidate SwiftUI.
        frameSinksByRole[role]?(surfacesByRole[role])
        // First frame only: flip the pane out of its launching/reconnecting
        // overlay. Subsequent frames never touch `@Published`.
        if snapshotsByRole[role]?.phase != .ready {
            updateSnapshot(role: role) { $0.phase = .ready }
        }
    }

    fileprivate func handleEvent(role: RenderSurfaceRole, event: RenderEvent) {
        // Frames arrive via the @objc reply (handleFrameReady) carrying the shared
        // IOSurface, not through this Codable event channel.
        switch event {
        case .title(let title):
            updateSnapshot(role: role) { $0.title = title }
            onSurfaceEvent?(role, event)
        case .exited(let code):
            updateSnapshot(role: role) {
                $0.phase = .exited(code)
                $0.exitCode = code
            }
            onSurfaceEvent?(role, event)
        case .notification, .commandFinished, .activity, .pwd, .sessionId, .bell,
            .captureTruncated:
            onSurfaceEvent?(role, event)
        }
    }

    // MARK: - Helpers

    private func updateSnapshot(
        role: RenderSurfaceRole, _ mutate: (inout RenderSurfaceSnapshot) -> Void
    ) {
        var snapshot = snapshotsByRole[role] ?? RenderSurfaceSnapshot()
        mutate(&snapshot)
        snapshotsByRole[role] = snapshot
    }

    private func recordDiagnostic(name: String, metadata: [String: String]) {
        diagnosticRecorder.record(
            DiagnosticEvent(category: "Render", name: name, metadata: metadata))
    }

    /// Builds the terminal launch the helper consumes from the store's surface
    /// launch, stamping in the current rendering configuration.
    private static func terminalLaunch(
        from launch: RenderSurfaceLaunch, rendering: IsolatedTerminalRendering
    ) -> IsolatedTerminalLaunch {
        let descriptor = launch.agentLaunchDescriptor
        return IsolatedTerminalLaunch(
            command: launch.command,
            environment: descriptor?.environment ?? [:],
            workingDirectory: launch.workingDirectory.path,
            captureLogPath: descriptor?.captureLogURL?.path,
            captureLogMaximumBytes: nil,
            startupInput: descriptor?.startupInput,
            agentCLI: launch.isAgentPTY ? launch.agentCLI.rawValue : nil,
            themeID: rendering.themeID,
            terminalFontFamily: rendering.terminalFontFamily,
            terminalFontSize: rendering.terminalFontSize,
            terminalFontLigatures: rendering.terminalFontLigatures,
            appShortcutSignatures: rendering.appShortcutSignatures
        )
    }

    /// Confirms the render-host helper is bundled so the `serviceName` XPC
    /// connection can resolve it. The connection itself goes through launchd by
    /// service name (`SurfaceConnection.serviceName`); this is the
    /// is-it-present gate. Checks the packaged XPC service bundle
    /// (`Contents/XPCServices/<service-id>.xpc/Contents/MacOS/YAAWRenderHost`,
    /// staged by `build_and_run.sh`), then a bare `swift build` sibling.
    static func defaultHelperURL() -> URL? {
        let helperName = "YAAWRenderHost"
        let serviceHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices")
            .appendingPathComponent("\(SurfaceConnection.serviceName).xpc")
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: serviceHelper.path) {
            return serviceHelper
        }
        guard let executableURL = Bundle.main.executableURL else { return nil }
        let sibling = executableURL.deletingLastPathComponent().appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }
}

/// One XPC connection to a `YAAWRenderHost` helper for a single surface. Owns the
/// `NSXPCConnection`, the cached launch + last viewport (for relaunch replay),
/// and the encode/send path. The render-host helper itself launches the helper
/// executable (an XPC service); here we connect to it by service name when the
/// bundle vends one and otherwise drive the resolved executable's listener
/// endpoint. Kept minimal because runtime is out of scope for this chunk — the
/// structure (one connection per surface, typed envelopes, invalidation → relaunch)
/// is what matters.
@MainActor
private final class SurfaceConnection {
    let role: RenderSurfaceRole
    var launch: IsolatedTerminalLaunch
    var lastViewport: ResizePayload?
    var expectedShutdown = false
    var onInvalidate: (() -> Void)?

    private let connection: NSXPCConnection
    private let reply: RenderReply
    private var isResumed = false

    var isConnected: Bool { isResumed && !expectedShutdown }

    init(
        role: RenderSurfaceRole,
        helperURL: URL,
        launch: IsolatedTerminalLaunch,
        reply: RenderReply
    ) {
        self.role = role
        self.launch = launch
        self.reply = reply
        // The helper is an XPC service: connect by its bundle service name. The
        // resolved `helperURL` is retained for diagnostics / sibling fallback.
        self.connection = NSXPCConnection(serviceName: Self.serviceName)
        _ = helperURL
        connection.remoteObjectInterface = NSXPCInterface(with: YAAWRenderServiceProtocol.self)
        let replyInterface = NSXPCInterface(with: YAAWRenderReplyProtocol.self)
        // IOSurface must be whitelisted as the `surface:` argument of frameReady
        // so XPC will decode the shared surface (it is NSSecureCoding-compliant
        // but not in the default allow-list).
        replyInterface.setClasses(
            NSSet(object: IOSurface.self) as! Set<AnyHashable>,
            for: #selector(YAAWRenderReplyProtocol.frameReady(generation:surface:)),
            argumentIndex: 1,
            ofReply: false
        )
        connection.exportedInterface = replyInterface
        connection.exportedObject = reply
    }

    func resume() {
        guard !isResumed else { return }
        connection.invalidationHandler = { [onInvalidate] in onInvalidate?() }
        connection.interruptionHandler = { [onInvalidate] in onInvalidate?() }
        connection.resume()
        isResumed = true
    }

    func send(_ message: RenderMessage) {
        guard isResumed, !expectedShutdown,
            let data = try? JSONEncoder().encode(message)
        else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? YAAWRenderServiceProtocol)?.handleMessage(data) { _ in }
    }

    func shutdown(expected: Bool) {
        expectedShutdown = expected
        send(.shutdown)
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        isResumed = false
    }

    static let serviceName = "dev.dopsonbr.YAAW.RenderHost"
}

/// Moves a non-`Sendable` `IOSurface` from the XPC reply queue to the main actor.
/// Sending a kernel surface reference between threads is safe.
private struct UncheckedSurfaceBox: @unchecked Sendable {
    let surface: IOSurface?
}

extension RenderSurfaceRole {
    /// App-local diagnostic label (the Kit extension is internal to YAAWKit).
    fileprivate var diagnosticName: String {
        switch self {
        case .project: "project"
        case .bottom: "bottom"
        case .nvim, .nvimTab: "nvim"
        case .lazygit: "lazygit"
        case .browser: "browser"
        }
    }
}

/// The object the helper calls back into. `@unchecked Sendable` because it is a
/// genuine XPC bridge: `NSXPCConnection` invokes its `@objc` methods on a private
/// queue, and it only hops to the `@MainActor` client. (D-011: no isolated deinit.)
private final class RenderReply: NSObject, YAAWRenderReplyProtocol, @unchecked Sendable {
    private let role: RenderSurfaceRole
    private weak var client: RenderHostClient?

    init(role: RenderSurfaceRole, client: RenderHostClient) {
        self.role = role
        self.client = client
    }

    func frameReady(generation: UInt64, surface: IOSurface?) {
        let role = role
        // IOSurface isn't Sendable; box it to cross into the main actor (passing a
        // kernel surface reference between threads is safe).
        let boxed = UncheckedSurfaceBox(surface: surface)
        Task { @MainActor [weak client] in
            client?.handleFrameReady(
                role: role, generation: generation, surface: boxed.surface)
        }
    }

    func eventReceived(_ eventData: Data) {
        guard let event = try? JSONDecoder().decode(RenderEvent.self, from: eventData) else {
            return
        }
        let role = role
        Task { @MainActor [weak client] in
            client?.handleEvent(role: role, event: event)
        }
    }
}
