import Foundation

public enum ExternalOpenToolID: String, CaseIterable, Codable, Equatable, Hashable, Identifiable,
    Sendable
{
    case vscode
    case vscodeInsiders = "vscode-insiders"
    case sublimeText = "sublime-text"
    case zed
    case finder
    case terminal
    case ghostty
    case xcode
    case webstorm

    public var id: String { rawValue }

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

    public var isEditor: Bool {
        switch self {
        case .vscode, .vscodeInsiders, .sublimeText, .zed, .xcode, .webstorm:
            return true
        case .finder, .terminal, .ghostty:
            return false
        }
    }

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

public struct ExternalOpenSettings: Codable, Equatable, Sendable {
    public static let defaultTool: ExternalOpenToolID = .zed
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

    public var `default`: String
    public var preferred: [String]

    public init(
        default: String = Self.defaultTool.rawValue,
        preferred: [String] = Self.defaultPreferred.map(\.rawValue)
    ) {
        self.default = `default`
        self.preferred = preferred
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.default =
            try container.decodeIfPresent(String.self, forKey: .default)
            ?? Self.defaultTool.rawValue
        self.preferred =
            try container.decodeIfPresent([String].self, forKey: .preferred)
            ?? Self.defaultPreferred.map(\.rawValue)
    }

    public var defaultToolID: ExternalOpenToolID {
        ExternalOpenToolID(rawValue: `default`) ?? Self.defaultTool
    }

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

public enum ExternalOpenTargetKind: Equatable, Sendable {
    case directory
    case file
}

public struct ExternalOpenTarget: Equatable, Sendable {
    public var url: URL
    public var kind: ExternalOpenTargetKind

    public init(url: URL, kind: ExternalOpenTargetKind) {
        self.url = url
        self.kind = kind
    }

    public func launchURL(for tool: ExternalOpenToolID) -> URL {
        switch (kind, tool) {
        case (.file, .terminal), (.file, .ghostty):
            return url.deletingLastPathComponent()
        default:
            return url
        }
    }

    public func shouldRevealInFinder(for tool: ExternalOpenToolID) -> Bool {
        kind == .file && tool == .finder
    }
}

public enum ExternalOpenToolResolver {
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

    public static func availableEditorTools(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> [ExternalOpenToolID] {
        availableTools(settings: settings, detectedTools: detectedTools).filter(\.isEditor)
    }

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
