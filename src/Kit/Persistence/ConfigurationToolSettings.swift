import Foundation

public struct ToolSettings: Codable, Equatable, Sendable {
    public var editors: EditorToolSettings
    public var externalOpen: ExternalOpenSettings
    public var git: GitToolSettings
    public var diff: DiffToolSettings
    public var agents: AgentToolSettings

    public init(
        editors: EditorToolSettings = EditorToolSettings(),
        externalOpen: ExternalOpenSettings = ExternalOpenSettings(),
        git: GitToolSettings = GitToolSettings(),
        diff: DiffToolSettings = DiffToolSettings(),
        agents: AgentToolSettings = AgentToolSettings()
    ) {
        self.editors = editors
        self.externalOpen = externalOpen
        self.git = git
        self.diff = diff
        self.agents = agents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.editors =
            try container.decodeIfPresent(EditorToolSettings.self, forKey: .editors)
            ?? EditorToolSettings()
        self.externalOpen =
            try container.decodeIfPresent(
                ExternalOpenSettings.self,
                forKey: .externalOpen
            ) ?? ExternalOpenSettings()
        self.git =
            try container.decodeIfPresent(GitToolSettings.self, forKey: .git) ?? GitToolSettings()
        self.diff =
            try container.decodeIfPresent(DiffToolSettings.self, forKey: .diff)
            ?? DiffToolSettings()
        self.agents =
            try container.decodeIfPresent(AgentToolSettings.self, forKey: .agents)
            ?? AgentToolSettings()
    }

    internal func validated() -> ToolSettings {
        ToolSettings(
            editors: editors.validated(),
            externalOpen: externalOpen.validated(),
            git: git.validated(),
            diff: diff.validated(),
            agents: agents.validated()
        )
    }
}

public struct EditorToolSettings: Codable, Equatable, Sendable {
    public var preferred: [String]

    public init(preferred: [String] = ["nvim", "vim", "vi"]) {
        self.preferred = preferred
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preferred =
            try container.decodeIfPresent([String].self, forKey: .preferred) ?? [
                "nvim", "vim", "vi",
            ]
    }

    internal func validated() -> EditorToolSettings {
        let names = preferred.nonBlankValues
        return EditorToolSettings(preferred: names.isEmpty ? ["nvim", "vim", "vi"] : names)
    }
}

public struct GitToolSettings: Codable, Equatable, Sendable {
    public var preferred: String

    public init(preferred: String = "lazygit") {
        self.preferred = preferred
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preferred = try container.decodeIfPresent(String.self, forKey: .preferred) ?? "lazygit"
    }

    internal func validated() -> GitToolSettings {
        let name = preferred.trimmed
        return GitToolSettings(preferred: name.isEmpty ? "lazygit" : name)
    }
}

public struct DiffToolSettings: Codable, Equatable, Sendable {
    public var fallback: [String]

    public init(fallback: [String] = ["git", "diff"]) {
        self.fallback = fallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fallback =
            try container.decodeIfPresent([String].self, forKey: .fallback) ?? ["git", "diff"]
    }

    internal func validated() -> DiffToolSettings {
        let command = fallback.nonBlankValues
        return DiffToolSettings(fallback: command.isEmpty ? ["git", "diff"] : command)
    }
}

public struct AgentToolSettings: Codable, Equatable, Sendable {
    public var codex: String
    public var claude: String
    public var opencode: String
    public var copilot: String

    public init(
        codex: String = "codex",
        claude: String = "claude",
        opencode: String = "opencode",
        copilot: String = "copilot"
    ) {
        self.codex = codex
        self.claude = claude
        self.opencode = opencode
        self.copilot = copilot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codex = try container.decodeIfPresent(String.self, forKey: .codex) ?? "codex"
        self.claude = try container.decodeIfPresent(String.self, forKey: .claude) ?? "claude"
        self.opencode = try container.decodeIfPresent(String.self, forKey: .opencode) ?? "opencode"
        self.copilot = try container.decodeIfPresent(String.self, forKey: .copilot) ?? "copilot"
    }

    public func executableName(for kind: AgentCLIKind) -> String {
        switch kind {
        case .codex:
            codex
        case .claude:
            claude
        case .opencode:
            opencode
        case .copilot:
            copilot
        }
    }

    public mutating func setExecutableName(_ executableName: String, for kind: AgentCLIKind) {
        switch kind {
        case .codex:
            codex = executableName
        case .claude:
            claude = executableName
        case .opencode:
            opencode = executableName
        case .copilot:
            copilot = executableName
        }
    }

    internal func validated() -> AgentToolSettings {
        AgentToolSettings(
            codex: codex.nonBlankOr("codex"),
            claude: claude.nonBlankOr("claude"),
            opencode: opencode.nonBlankOr("opencode"),
            copilot: copilot.nonBlankOr("copilot")
        )
    }
}

public enum FileBrowserMarkdownAndHTMLDefault: String, CaseIterable, Codable, Equatable, Sendable {
    case browserPreview
    case editor

    public var displayName: String {
        switch self {
        case .browserPreview:
            "Browser preview"
        case .editor:
            "Built-in editor"
        }
    }
}

public struct FileBrowserSettings: Codable, Equatable, Sendable {
    public var markdownAndHTMLDefault: FileBrowserMarkdownAndHTMLDefault

    public init(
        markdownAndHTMLDefault: FileBrowserMarkdownAndHTMLDefault = .browserPreview
    ) {
        self.markdownAndHTMLDefault = markdownAndHTMLDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue =
            try container.decodeIfPresent(String.self, forKey: .markdownAndHTMLDefault)
            ?? FileBrowserMarkdownAndHTMLDefault.browserPreview.rawValue
        self.markdownAndHTMLDefault =
            FileBrowserMarkdownAndHTMLDefault(rawValue: rawValue)
            ?? .browserPreview
    }

    internal func validated() -> FileBrowserSettings {
        self
    }
}

public struct FileIndexingSettings: Codable, Equatable, Sendable {
    public var ignoreRules: [String]

    public init(ignoreRules: [String] = Self.defaultIgnoreRules) {
        self.ignoreRules = ignoreRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ignoreRules =
            try container.decodeIfPresent([String].self, forKey: .ignoreRules)
            ?? Self.defaultIgnoreRules
    }

    public static let defaultIgnoreRules = [
        ".git",
        "node_modules",
        "dist",
        ".build",
        "DerivedData",
        ".angular",
        ".venv",
        "venv",
        ".cache",
        ".next",
        ".nuxt",
        "target",
        "vendor",
        ".idea",
        ".vscode",
        "worktrees",
    ]
}
