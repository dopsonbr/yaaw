import Foundation

public enum IsolatedToolKind: String, Codable, Equatable, Sendable {
    case browser
    case terminal
}

public enum IsolatedToolRuntimePhase: String, Codable, Equatable, Sendable {
    case idle
    case launching
    case ready
    case loading
    case failed
    case crashed
    case exited
}

public struct IsolatedToolEnvelope: Codable, Equatable, Sendable {
    // v2 adds the `terminal` tool kind and terminal-specific message types
    // (launchTerminal, focus, input, resize, exited, setRenderingConfiguration).
    // The helper is bundled with the app, so parent and child are always built
    // in lockstep.
    public static let currentProtocolVersion = 2

    public var protocolVersion: Int
    public var toolKind: IsolatedToolKind
    public var instanceID: String
    public var messageID: String
    public var type: String
    public var payload: [String: String]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        toolKind: IsolatedToolKind,
        instanceID: String,
        messageID: String = UUID().uuidString,
        type: String,
        payload: [String: String] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.toolKind = toolKind
        self.instanceID = instanceID
        self.messageID = messageID
        self.type = type
        self.payload = payload
    }

    public func validated() throws -> Self {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw IsolatedToolProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard !instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IsolatedToolProtocolError.emptyInstanceID
        }
        guard !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IsolatedToolProtocolError.emptyMessageType
        }
        return self
    }
}

public enum IsolatedToolProtocolError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case emptyInstanceID
    case emptyMessageType
}

/// Launch configuration for a terminal helper, carried in the `launchTerminal`
/// envelope. `command`/`environment` are JSON-encoded into the flat
/// `[String: String]` payload so the envelope type stays unchanged. The capture
/// log is written by the helper at `captureLogPath`; the parent owns truncation.
public struct IsolatedTerminalLaunch: Equatable, Sendable {
    public var command: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var captureLogPath: String?
    public var captureLogMaximumBytes: Int?
    public var startupInput: String?
    public var agentCLI: String?
    public var themeID: String?
    public var terminalFontFamily: String?
    public var terminalFontSize: Double?
    /// `nil` means the default: ligatures enabled.
    public var terminalFontLigatures: Bool?
    public var appShortcutSignatures: [String]

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

    fileprivate static func nilIfBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    fileprivate static func decodeJSON<T: Decodable>(_ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Rendering-only configuration for a terminal helper: everything the helper
/// can apply to a live surface without restarting the hosted process. Carried
/// in the `setRenderingConfiguration` envelope and embedded in the launch.
public struct IsolatedTerminalRendering: Equatable, Sendable {
    public var themeID: String?
    public var terminalFontFamily: String?
    public var terminalFontSize: Double?
    /// `nil` means the default: ligatures enabled.
    public var terminalFontLigatures: Bool?
    public var appShortcutSignatures: [String]

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

    public func payload() -> [String: String] {
        var payload: [String: String] = [:]
        payload["themeID"] = themeID
        payload["terminalFontFamily"] = terminalFontFamily
        payload["terminalFontSize"] = terminalFontSize.map { String($0) }
        payload["terminalFontLigatures"] = terminalFontLigatures.map(String.init)
        payload["appShortcutSignatures"] = IsolatedTerminalLaunch.encodeJSON(appShortcutSignatures)
        return payload
    }

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

extension IsolatedTerminalLaunch {
    public var rendering: IsolatedTerminalRendering {
        IsolatedTerminalRendering(
            themeID: themeID,
            terminalFontFamily: terminalFontFamily,
            terminalFontSize: terminalFontSize,
            terminalFontLigatures: terminalFontLigatures,
            appShortcutSignatures: appShortcutSignatures
        )
    }

    public mutating func applyRendering(_ rendering: IsolatedTerminalRendering) {
        themeID = rendering.themeID
        terminalFontFamily = rendering.terminalFontFamily
        terminalFontSize = rendering.terminalFontSize
        terminalFontLigatures = rendering.terminalFontLigatures
        appShortcutSignatures = rendering.appShortcutSignatures
    }

    /// True when both launches describe the same hosted process — every field
    /// except the rendering configuration matches. Compared by normalizing the
    /// rendering on copies and using the synthesized `==`, so any field added
    /// to the launch later defaults to process identity (safe: restart).
    public func processIdentityMatches(_ other: IsolatedTerminalLaunch) -> Bool {
        var lhs = self
        var rhs = other
        lhs.applyRendering(IsolatedTerminalRendering())
        rhs.applyRendering(IsolatedTerminalRendering())
        return lhs == rhs
    }
}

/// Classifies what `ensureTerminalLaunched` must do when the view supplies a
/// (possibly changed) launch for an instance.
public enum IsolatedTerminalLaunchTransition: Equatable, Sendable {
    /// No helper is tracked for the instance — start one.
    case launchNew
    /// The launch is unchanged — nothing to do.
    case noChange
    /// Only rendering fields changed — update the live helper in place.
    case updateRendering
    /// The hosted process itself changed — tear down and relaunch.
    case relaunchProcess

    public static func between(
        _ existing: IsolatedTerminalLaunch?,
        _ next: IsolatedTerminalLaunch
    ) -> Self {
        guard let existing else { return .launchNew }
        if existing == next { return .noChange }
        return existing.processIdentityMatches(next) ? .updateRendering : .relaunchProcess
    }
}

public struct IsolatedToolRuntimeSnapshot: Equatable, Sendable {
    public var phase: IsolatedToolRuntimePhase
    public var title: String
    public var urlString: String?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var errorMessage: String?
    /// Exit status of the hosted process when `phase == .exited` (terminal kind).
    public var exitCode: Int32?

    public init(
        phase: IsolatedToolRuntimePhase = .idle,
        title: String = "",
        urlString: String? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        errorMessage: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.phase = phase
        self.title = title
        self.urlString = urlString
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.errorMessage = errorMessage
        self.exitCode = exitCode
    }
}

public enum IsolatedToolRuntimeAction: Equatable, Sendable {
    case launch
    case ready
    case stateChanged([String: String])
    case titleChanged(String)
    case error(String)
    /// Process/command finished. Carries an exit code for the terminal kind
    /// (nil when the helper process simply exited without a reported code).
    case exited(Int32?)
    case crashed(String)
}

public enum IsolatedToolRuntimeReducer {
    public static func reduce(
        _ snapshot: IsolatedToolRuntimeSnapshot,
        action: IsolatedToolRuntimeAction
    ) -> IsolatedToolRuntimeSnapshot {
        var next = snapshot
        switch action {
        case .launch:
            next.phase = .launching
            next.errorMessage = nil
            next.exitCode = nil
        case .ready:
            next.phase = .ready
            next.errorMessage = nil
        case .stateChanged(let payload):
            if let title = payload["title"] {
                next.title = title
            }
            if let urlString = payload["urlString"] {
                next.urlString = urlString.isEmpty ? nil : urlString
            }
            if let isLoading = payload["isLoading"].flatMap(Bool.init) {
                next.isLoading = isLoading
                next.phase = isLoading ? .loading : .ready
            }
            if let canGoBack = payload["canGoBack"].flatMap(Bool.init) {
                next.canGoBack = canGoBack
            }
            if let canGoForward = payload["canGoForward"].flatMap(Bool.init) {
                next.canGoForward = canGoForward
            }
            next.errorMessage = nil
        case .titleChanged(let title):
            next.title = title
        case .error(let message):
            next.phase = .failed
            next.isLoading = false
            next.errorMessage = message
        case .exited(let code):
            next.phase = .exited
            next.isLoading = false
            if let code {
                next.exitCode = code
            }
        case .crashed(let message):
            next.phase = .crashed
            next.isLoading = false
            next.errorMessage = message
        }
        return next
    }
}
