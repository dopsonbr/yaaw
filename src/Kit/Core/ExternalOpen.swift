import Foundation

/// Identifies an external application YAAW can hand a file or directory off to.
public enum ExternalOpenToolID: String, CaseIterable, Codable, Equatable, Hashable, Identifiable,
    Sendable
{
    /// Visual Studio Code.
    case vscode
    /// Visual Studio Code Insiders.
    case vscodeInsiders = "vscode-insiders"
    /// Sublime Text.
    case sublimeText = "sublime-text"
    /// Zed.
    case zed
    /// The macOS Finder.
    case finder
    /// The macOS Terminal.
    case terminal
    /// Ghostty.
    case ghostty
    /// Xcode.
    case xcode
    /// WebStorm.
    case webstorm

    /// The stable identifier for this tool (its raw value).
    public var id: String { rawValue }

    /// The human-readable name shown in menus and settings.
    public var displayName: String {
        switch self {
        case .vscode:
            return "VS Code"
        case .vscodeInsiders:
            return "VS Code Insiders"
        case .sublimeText:
            return "Sublime Text"
        case .zed:
            return "Zed"
        case .finder:
            return "Finder"
        case .terminal:
            return "Terminal"
        case .ghostty:
            return "Ghostty"
        case .xcode:
            return "Xcode"
        case .webstorm:
            return "WebStorm"
        }
    }

    /// Whether this tool is a code editor (as opposed to Finder or a terminal).
    public var isEditor: Bool {
        switch self {
        case .vscode, .vscodeInsiders, .sublimeText, .zed, .xcode, .webstorm:
            return true
        case .finder, .terminal, .ghostty:
            return false
        }
    }

    /// The SF Symbol name used to represent this tool in the UI.
    public var systemSymbolName: String {
        switch self {
        case .finder:
            return "face.smiling"
        case .terminal, .ghostty:
            return "terminal"
        case .xcode:
            return "hammer"
        case .webstorm:
            return "w.square"
        case .vscode, .vscodeInsiders, .sublimeText, .zed:
            return "curlybraces.square"
        }
    }
}

/// User configuration for opening files and directories in external tools: the
/// preferred default tool and the ordered list of tools to offer.
public struct ExternalOpenSettings: Codable, Equatable, Sendable {
    /// The tool used as the default when none is configured.
    public static let defaultTool: ExternalOpenToolID = .zed
    /// The default ordered list of preferred tools.
    public static let defaultPreferred: [ExternalOpenToolID] = [
        .vscode,
        .vscodeInsiders,
        .sublimeText,
        .zed,
        .finder,
        .terminal,
        .ghostty,
        .xcode,
        .webstorm,
    ]

    /// The raw value of the configured default tool.
    public var `default`: String
    /// The raw values of the configured preferred tools, in priority order.
    public var preferred: [String]

    /// Creates settings from raw tool identifiers, defaulting to the built-in values.
    public init(
        default: String = Self.defaultTool.rawValue,
        preferred: [String] = Self.defaultPreferred.map(\.rawValue)
    ) {
        self.default = `default`
        self.preferred = preferred
    }

    /// Decodes settings, falling back to the built-in defaults for missing keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.default =
            try container.decodeIfPresent(String.self, forKey: .default)
            ?? Self.defaultTool.rawValue
        self.preferred =
            try container.decodeIfPresent([String].self, forKey: .preferred)
            ?? Self.defaultPreferred.map(\.rawValue)
    }

    /// The configured default tool, falling back to ``defaultTool`` if invalid.
    public var defaultToolID: ExternalOpenToolID {
        ExternalOpenToolID(rawValue: `default`) ?? Self.defaultTool
    }

    /// The configured preferred tools as parsed, de-duplicated identifiers,
    /// falling back to ``defaultPreferred`` if none are valid.
    public var preferredToolIDs: [ExternalOpenToolID] {
        var seen = Set<ExternalOpenToolID>()
        var tools: [ExternalOpenToolID] = []
        for value in preferred {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tool = ExternalOpenToolID(rawValue: normalized),
                seen.insert(tool).inserted
            else {
                continue
            }
            tools.append(tool)
        }
        return tools.isEmpty ? Self.defaultPreferred : tools
    }

    func validated() -> ExternalOpenSettings {
        let defaultTool = defaultToolID
        let preferredTools = preferredToolIDs
        return ExternalOpenSettings(
            default: defaultTool.rawValue,
            preferred: preferredTools.map(\.rawValue)
        )
    }
}

/// Whether an external-open target is a directory or a file.
public enum ExternalOpenTargetKind: Equatable, Sendable {
    /// The target is a directory.
    case directory
    /// The target is a file.
    case file
}

/// A filesystem location to open externally, paired with whether it is a file or
/// a directory.
public struct ExternalOpenTarget: Equatable, Sendable {
    /// The location of the target.
    public var url: URL
    /// Whether the target is a file or a directory.
    public var kind: ExternalOpenTargetKind

    /// Creates a target for the given URL and kind.
    public init(url: URL, kind: ExternalOpenTargetKind) {
        self.url = url
        self.kind = kind
    }

    /// Returns the URL to launch for the given tool. For files opened in a
    /// terminal, this is the containing directory; otherwise it is the target URL.
    public func launchURL(for tool: ExternalOpenToolID) -> URL {
        switch (kind, tool) {
        case (.file, .terminal), (.file, .ghostty):
            return url.deletingLastPathComponent()
        default:
            return url
        }
    }

    /// Whether opening this target in the given tool should reveal it in Finder
    /// (true only for files opened with Finder).
    public func shouldRevealInFinder(for tool: ExternalOpenToolID) -> Bool {
        kind == .file && tool == .finder
    }
}

/// Resolves which external tools are offered and chosen as defaults, based on the
/// user's settings and the set of tools detected on the system.
public enum ExternalOpenToolResolver {
    /// Returns the preferred tools that are installed, ensuring Finder is offered
    /// when no editor is available.
    public static func availableTools(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> [ExternalOpenToolID] {
        var tools = settings.preferredToolIDs.filter { detectedTools.contains($0) }
        if !tools.contains(where: \.isEditor),
            detectedTools.contains(.finder),
            !tools.contains(.finder)
        {
            tools.append(.finder)
        }
        return tools
    }

    /// Returns the tool to use by default: the configured default if available,
    /// otherwise the first available tool, or `nil` if none are available.
    public static func defaultTool(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> ExternalOpenToolID? {
        let available = availableTools(settings: settings, detectedTools: detectedTools)
        let configuredDefault = settings.defaultToolID
        if available.contains(configuredDefault) {
            return configuredDefault
        }
        return available.first
    }

    /// Returns the available tools restricted to editors.
    public static func availableEditorTools(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> [ExternalOpenToolID] {
        availableTools(settings: settings, detectedTools: detectedTools).filter(\.isEditor)
    }

    /// Returns the editor to use by default: the configured default if it is an
    /// available editor, otherwise the first available editor, or `nil` if none.
    public static func defaultEditorTool(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> ExternalOpenToolID? {
        let available = availableEditorTools(settings: settings, detectedTools: detectedTools)
        let configuredDefault = settings.defaultToolID
        if configuredDefault.isEditor, available.contains(configuredDefault) {
            return configuredDefault
        }
        return available.first
    }
}
