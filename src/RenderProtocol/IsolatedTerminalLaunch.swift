import Foundation

/// Launch configuration for a terminal render helper.
///
/// Carries everything needed to start the hosted PTY process plus the rendering
/// configuration (theme/font/ligatures) to apply to the emulator. `command` and
/// `environment` are JSON-encoded into the flat `[String: String]` ``payload()``
/// representation so the value can travel over a string-keyed wire without
/// changing the envelope shape; the typed ``LaunchPayload`` Codable envelope is
/// the preferred transport, with ``payload()`` retained for round-trip parity.
///
/// The capture log is written by the helper at ``captureLogPath``; the app owns
/// truncation policy. Blank `themeID`/`terminalFontFamily` strings normalize to
/// `nil` so an empty settings field behaves like "default".
public struct IsolatedTerminalLaunch: Equatable, Sendable {
    /// The exec argv of the hosted process.
    public var command: [String]
    /// Full environment for the process, or empty to inherit the helper's env.
    public var environment: [String: String]
    /// Working directory the process is launched in.
    public var workingDirectory: String
    /// Path the helper writes the PTY capture log to, if any.
    public var captureLogPath: String?
    /// Maximum capture-log size in bytes before the circular buffer truncates.
    public var captureLogMaximumBytes: Int?
    /// Initial input pasted into the terminal after launch, if any.
    public var startupInput: String?
    /// The bound agent CLI family (`"claude"`/`"codex"`/etc.), if this is an agent.
    public var agentCLI: String?
    /// Theme identifier to render with; `nil` means default.
    public var themeID: String?
    /// Terminal font family to render with; `nil` means default.
    public var terminalFontFamily: String?
    /// Terminal font size in points; `nil` means default.
    public var terminalFontSize: Double?
    /// Whether font ligatures are enabled; `nil` means the default (enabled).
    public var terminalFontLigatures: Bool?
    /// Command-shortcut signatures the helper should pass through to the app.
    public var appShortcutSignatures: [String]

    /// Creates a terminal launch configuration.
    ///
    /// Blank `themeID`/`terminalFontFamily` values are normalized to `nil`.
    public init(
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
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.captureLogPath = captureLogPath
        self.captureLogMaximumBytes = captureLogMaximumBytes
        self.startupInput = startupInput
        self.agentCLI = agentCLI
        self.themeID = Self.nilIfBlank(themeID)
        self.terminalFontFamily = Self.nilIfBlank(terminalFontFamily)
        self.terminalFontSize = terminalFontSize
        self.terminalFontLigatures = terminalFontLigatures
        self.appShortcutSignatures = appShortcutSignatures
    }

    /// Encodes the launch into a flat string-keyed payload for legacy round-trip.
    public func payload() -> [String: String] {
        var payload: [String: String] = [
            "command": Self.encodeJSON(command) ?? "[]",
            "environment": Self.encodeJSON(environment) ?? "{}",
            "workingDirectory": workingDirectory,
        ]
        payload["captureLogPath"] = captureLogPath
        payload["captureLogMaximumBytes"] = captureLogMaximumBytes.map(String.init)
        payload["startupInput"] = startupInput
        payload["agentCLI"] = agentCLI
        payload["themeID"] = themeID
        payload["terminalFontFamily"] = terminalFontFamily
        payload["terminalFontSize"] = terminalFontSize.map { String($0) }
        payload["terminalFontLigatures"] = terminalFontLigatures.map(String.init)
        payload["appShortcutSignatures"] = Self.encodeJSON(appShortcutSignatures)
        return payload
    }

    /// Decodes a launch from a flat string-keyed payload, or `nil` if invalid.
    ///
    /// Returns `nil` when `command` is missing/empty or `workingDirectory` is
    /// absent — the two fields with no safe default.
    public static func from(payload: [String: String]) -> IsolatedTerminalLaunch? {
        guard let commandJSON = payload["command"],
            let command: [String] = decodeJSON(commandJSON),
            !command.isEmpty,
            let workingDirectory = payload["workingDirectory"]
        else { return nil }
        let environment: [String: String] =
            payload["environment"].flatMap(decodeJSON) ?? [:]
        return IsolatedTerminalLaunch(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory,
            captureLogPath: payload["captureLogPath"],
            captureLogMaximumBytes: payload["captureLogMaximumBytes"].flatMap(Int.init),
            startupInput: payload["startupInput"],
            agentCLI: payload["agentCLI"],
            themeID: payload["themeID"],
            terminalFontFamily: payload["terminalFontFamily"],
            terminalFontSize: payload["terminalFontSize"].flatMap(Double.init),
            terminalFontLigatures: payload["terminalFontLigatures"].flatMap(Bool.init),
            appShortcutSignatures: payload["appShortcutSignatures"].flatMap(decodeJSON) ?? []
        )
    }

    static func nilIfBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeJSON<T: Decodable>(_ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension IsolatedTerminalLaunch {
    /// The rendering-only subset of this launch (theme/font/ligatures/shortcuts).
    public var rendering: IsolatedTerminalRendering {
        IsolatedTerminalRendering(
            themeID: themeID,
            terminalFontFamily: terminalFontFamily,
            terminalFontSize: terminalFontSize,
            terminalFontLigatures: terminalFontLigatures,
            appShortcutSignatures: appShortcutSignatures
        )
    }

    /// Replaces this launch's rendering fields with `rendering`'s values.
    public mutating func applyRendering(_ rendering: IsolatedTerminalRendering) {
        themeID = rendering.themeID
        terminalFontFamily = rendering.terminalFontFamily
        terminalFontSize = rendering.terminalFontSize
        terminalFontLigatures = rendering.terminalFontLigatures
        appShortcutSignatures = rendering.appShortcutSignatures
    }

    /// True when both launches describe the same hosted process.
    ///
    /// Every field except the rendering configuration must match. Compared by
    /// normalizing the rendering on copies and using the synthesized `==`, so any
    /// field added to the launch later defaults to process identity (safe: a
    /// changed new field triggers a relaunch rather than a silent hot-reload).
    public func processIdentityMatches(_ other: IsolatedTerminalLaunch) -> Bool {
        var lhs = self
        var rhs = other
        lhs.applyRendering(IsolatedTerminalRendering())
        rhs.applyRendering(IsolatedTerminalRendering())
        return lhs == rhs
    }
}

/// Rendering-only configuration for a terminal helper.
///
/// Everything the helper can apply to a live surface without restarting the
/// hosted process. Carried in the `setRendering` message and embedded in the
/// launch. Blank `themeID`/`terminalFontFamily` strings normalize to `nil`.
public struct IsolatedTerminalRendering: Equatable, Sendable {
    /// Theme identifier to render with; `nil` means default.
    public var themeID: String?
    /// Terminal font family to render with; `nil` means default.
    public var terminalFontFamily: String?
    /// Terminal font size in points; `nil` means default.
    public var terminalFontSize: Double?
    /// Whether font ligatures are enabled; `nil` means the default (enabled).
    public var terminalFontLigatures: Bool?
    /// Command-shortcut signatures the helper should pass through to the app.
    public var appShortcutSignatures: [String]

    /// Creates a rendering configuration; blank strings normalize to `nil`.
    public init(
        themeID: String? = nil,
        terminalFontFamily: String? = nil,
        terminalFontSize: Double? = nil,
        terminalFontLigatures: Bool? = nil,
        appShortcutSignatures: [String] = []
    ) {
        self.themeID = IsolatedTerminalLaunch.nilIfBlank(themeID)
        self.terminalFontFamily = IsolatedTerminalLaunch.nilIfBlank(terminalFontFamily)
        self.terminalFontSize = terminalFontSize
        self.terminalFontLigatures = terminalFontLigatures
        self.appShortcutSignatures = appShortcutSignatures
    }

    /// Encodes the rendering into a flat string-keyed payload for round-trip.
    public func payload() -> [String: String] {
        var payload: [String: String] = [:]
        payload["themeID"] = themeID
        payload["terminalFontFamily"] = terminalFontFamily
        payload["terminalFontSize"] = terminalFontSize.map { String($0) }
        payload["terminalFontLigatures"] = terminalFontLigatures.map(String.init)
        payload["appShortcutSignatures"] = IsolatedTerminalLaunch.encodeJSON(appShortcutSignatures)
        return payload
    }

    /// Decodes a rendering from a flat string-keyed payload.
    public static func from(payload: [String: String]) -> IsolatedTerminalRendering {
        IsolatedTerminalRendering(
            themeID: payload["themeID"],
            terminalFontFamily: payload["terminalFontFamily"],
            terminalFontSize: payload["terminalFontSize"].flatMap(Double.init),
            terminalFontLigatures: payload["terminalFontLigatures"].flatMap(Bool.init),
            appShortcutSignatures: payload["appShortcutSignatures"]
                .flatMap(IsolatedTerminalLaunch.decodeJSON) ?? []
        )
    }
}

/// Classifies what the app must do when a view supplies a (possibly changed)
/// launch for a terminal surface.
public enum IsolatedTerminalLaunchTransition: Equatable, Sendable {
    /// No helper is tracked for the surface — start one.
    case launchNew
    /// The launch is unchanged — nothing to do.
    case noChange
    /// Only rendering fields changed — update the live helper in place.
    case updateRendering
    /// The hosted process itself changed — tear down and relaunch.
    case relaunchProcess

    /// Classifies the transition from `existing` to `next`.
    ///
    /// - `nil` existing → ``launchNew``.
    /// - Identical launches → ``noChange``.
    /// - Same process identity, different rendering → ``updateRendering``.
    /// - Different process identity → ``relaunchProcess``.
    public static func between(
        _ existing: IsolatedTerminalLaunch?,
        _ next: IsolatedTerminalLaunch
    ) -> Self {
        guard let existing else { return .launchNew }
        if existing == next { return .noChange }
        return existing.processIdentityMatches(next) ? .updateRendering : .relaunchProcess
    }
}
