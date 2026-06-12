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
    /// Hot-reload theme/font/ligatures on the live surface (no relaunch).
    case setRendering(RenderingPayload)
    /// Terminate the helper cleanly.
    case shutdown
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
