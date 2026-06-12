import Foundation

/// A downbound message from the app to a `YAAWRenderHost` helper.
///
/// These are the only commands the app sends. They are binary-safe `Codable`
/// envelopes (no base64): ``input(_:)`` carries raw `Data`, and frame buffers
/// never travel this channel — compositing is handled out of band via the `@objc`
/// `YAAWRenderReplyProtocol.frameReady(generation:surface:)` (shared `IOSurface`).
public enum RenderMessage: Codable, Equatable, Sendable {
    /// Initial setup: launch the hosted process/surface.
    case launch(LaunchPayload)
    /// The pane changed size; re-fit the grid and re-render.
    case resize(ResizePayload)
    /// Keyboard or paste input to inject into the surface.
    case input(InputPayload)
    /// A mouse event (button / move / drag / scroll) to inject into the surface.
    case mouse(MousePayload)
    /// Hot-reload theme/font/ligatures on the live surface (no relaunch).
    case setRendering(RenderingPayload)
    /// Terminate the helper cleanly.
    case shutdown
}

/// A mouse event forwarded from the app pane to a helper surface, sent in
/// ``RenderMessage/mouse(_:)``.
///
/// Coordinates are **pane-local points in a top-left origin** (the app pane is a
/// flipped `NSView`, and libghostty's `mousePoint` likewise yields top-left), so
/// the helper can map them straight onto its surface without another flip.
/// `modifierFlags` is the raw `NSEvent.ModifierFlags` value so the helper can
/// rebuild the exact modifier set. Terminal helpers feed these to libghostty
/// (which emits the right SGR/X11 sequences per the terminal's mouse mode);
/// browser helpers translate scroll/click to WebKit actions.
public struct MousePayload: Codable, Equatable, Sendable {
    /// The kind of mouse event.
    public enum Action: String, Codable, Sendable {
        case down, up, dragged, moved, scroll
    }
    /// Which button the event concerns (ignored for `.moved`/`.scroll`).
    public enum Button: String, Codable, Sendable { case left, right, middle }

    /// What happened.
    public var action: Action
    /// The button for `.down`/`.up`/`.dragged`.
    public var button: Button
    /// Pane-local X in points (top-left origin).
    public var x: Double
    /// Pane-local Y in points (top-left origin).
    public var y: Double
    /// Raw `NSEvent.ModifierFlags` value.
    public var modifierFlags: UInt
    /// Scroll delta X in points (for `.scroll`).
    public var scrollDeltaX: Double
    /// Scroll delta Y in points (for `.scroll`).
    public var scrollDeltaY: Double
    /// Whether the scroll deltas are precise (trackpad) vs line-based (wheel).
    public var hasPreciseScrolling: Bool

    /// Creates a mouse payload.
    public init(
        action: Action,
        button: Button = .left,
        x: Double,
        y: Double,
        modifierFlags: UInt = 0,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        hasPreciseScrolling: Bool = false
    ) {
        self.action = action
        self.button = button
        self.x = x
        self.y = y
        self.modifierFlags = modifierFlags
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.hasPreciseScrolling = hasPreciseScrolling
    }
}

/// Initial setup parameters for a render helper, sent in ``RenderMessage/launch(_:)``.
public struct LaunchPayload: Codable, Equatable, Sendable {
    /// `"terminal"` or `"browser"`.
    public var toolKind: String
    /// The exec argv of the hosted process.
    public var command: [String]
    /// Full environment, or empty to inherit the helper's env.
    public var environment: [String: String]
    /// Working directory the process is launched in.
    public var workingDirectory: String
    /// Terminal: path the helper writes the PTY capture log to, if any.
    public var captureLogPath: String?
    /// Terminal: maximum capture-log size in bytes before truncation.
    public var captureLogMaximumBytes: Int?
    /// Terminal: initial input pasted after launch, if any.
    public var startupInput: String?
    /// Terminal: the bound agent CLI family (`"claude"`/`"codex"`/etc.).
    public var agentCLI: String?
    /// Theme identifier to render with; `nil` means default.
    public var themeID: String?
    /// Terminal font family to render with; `nil` means default.
    public var terminalFontFamily: String?
    /// Terminal font size in points; `nil` means default.
    public var terminalFontSize: Double?
    /// Whether ligatures are enabled; `nil` means the default (enabled).
    public var terminalFontLigatures: Bool?
    /// Command-shortcut signatures to pass through to the app.
    public var appShortcutSignatures: [String]

    /// Creates a launch payload.
    public init(
        toolKind: String,
        command: [String],
        environment: [String: String] = [:],
        workingDirectory: String,
        captureLogPath: String? = nil,
        captureLogMaximumBytes: Int? = nil,
        startupInput: String? = nil,
        agentCLI: String? = nil,
        themeID: String? = nil,
        terminalFontFamily: String? = nil,
        terminalFontSize: Double? = nil,
        terminalFontLigatures: Bool? = nil,
        appShortcutSignatures: [String] = []
    ) {
        self.toolKind = toolKind
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.captureLogPath = captureLogPath
        self.captureLogMaximumBytes = captureLogMaximumBytes
        self.startupInput = startupInput
        self.agentCLI = agentCLI
        self.themeID = themeID
        self.terminalFontFamily = terminalFontFamily
        self.terminalFontSize = terminalFontSize
        self.terminalFontLigatures = terminalFontLigatures
        self.appShortcutSignatures = appShortcutSignatures
    }
}

/// Pane-size change parameters, sent in ``RenderMessage/resize(_:)``.
public struct ResizePayload: Codable, Equatable, Sendable {
    /// Terminal grid columns.
    public var columns: UInt32
    /// Terminal grid rows.
    public var rows: UInt32
    /// Pane width in backing-store pixels.
    public var widthPixels: UInt32
    /// Pane height in backing-store pixels.
    public var heightPixels: UInt32
    /// Display backing scale (e.g. `2.0` or `3.0`).
    public var contentsScale: Double

    /// Creates a resize payload.
    public init(
        columns: UInt32,
        rows: UInt32,
        widthPixels: UInt32,
        heightPixels: UInt32,
        contentsScale: Double
    ) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.contentsScale = contentsScale
    }
}

/// Raw input bytes, sent in ``RenderMessage/input(_:)``.
///
/// Carries `Data` directly (binary-safe, no base64 overhead).
public struct InputPayload: Codable, Equatable, Sendable {
    /// The raw bytes to inject (keyboard, paste, or host-injected).
    public var data: Data

    /// Creates an input payload from raw bytes.
    public init(data: Data) {
        self.data = data
    }
}

/// Hot-reload rendering parameters, sent in ``RenderMessage/setRendering(_:)``.
public struct RenderingPayload: Codable, Equatable, Sendable {
    /// Theme identifier to render with; `nil` means default.
    public var themeID: String?
    /// Terminal font family to render with; `nil` means default.
    public var terminalFontFamily: String?
    /// Terminal font size in points; `nil` means default.
    public var terminalFontSize: Double?
    /// Whether ligatures are enabled; `nil` means the default (enabled).
    public var terminalFontLigatures: Bool?
    /// Command-shortcut signatures to pass through to the app.
    public var appShortcutSignatures: [String]

    /// Creates a rendering payload.
    public init(
        themeID: String? = nil,
        terminalFontFamily: String? = nil,
        terminalFontSize: Double? = nil,
        terminalFontLigatures: Bool? = nil,
        appShortcutSignatures: [String] = []
    ) {
        self.themeID = themeID
        self.terminalFontFamily = terminalFontFamily
        self.terminalFontSize = terminalFontSize
        self.terminalFontLigatures = terminalFontLigatures
        self.appShortcutSignatures = appShortcutSignatures
    }
}

extension LaunchPayload {
    /// Builds a launch payload from an ``IsolatedTerminalLaunch`` for the
    /// terminal tool kind.
    public init(terminal launch: IsolatedTerminalLaunch) {
        self.init(
            toolKind: IsolatedToolKind.terminal.rawValue,
            command: launch.command,
            environment: launch.environment,
            workingDirectory: launch.workingDirectory,
            captureLogPath: launch.captureLogPath,
            captureLogMaximumBytes: launch.captureLogMaximumBytes,
            startupInput: launch.startupInput,
            agentCLI: launch.agentCLI,
            themeID: launch.themeID,
            terminalFontFamily: launch.terminalFontFamily,
            terminalFontSize: launch.terminalFontSize,
            terminalFontLigatures: launch.terminalFontLigatures,
            appShortcutSignatures: launch.appShortcutSignatures
        )
    }

    /// Builds a launch payload for the browser tool kind. The browser hosts a
    /// `WKWebView` (no PTY/capture/theme), so only the navigation `command`
    /// (`["load", urlString]`), working directory, and environment carry over.
    public init(browser launch: IsolatedTerminalLaunch) {
        self.init(
            toolKind: IsolatedToolKind.browser.rawValue,
            command: launch.command,
            environment: launch.environment,
            workingDirectory: launch.workingDirectory
        )
    }
}

extension RenderingPayload {
    /// Builds a rendering payload from an ``IsolatedTerminalRendering``.
    public init(rendering: IsolatedTerminalRendering) {
        self.init(
            themeID: rendering.themeID,
            terminalFontFamily: rendering.terminalFontFamily,
            terminalFontSize: rendering.terminalFontSize,
            terminalFontLigatures: rendering.terminalFontLigatures,
            appShortcutSignatures: rendering.appShortcutSignatures
        )
    }
}
