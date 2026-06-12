import Foundation

/// User-configurable settings for the external and built-in tools YAAW launches.
public struct ToolSettings: Codable, Equatable, Sendable {
    /// Settings for the editors used to open files.
    public var editors: EditorToolSettings
    /// Settings for opening files and URLs in external applications.
    public var externalOpen: ExternalOpenSettings
    /// Settings for the git UI tool.
    public var git: GitToolSettings
    /// Settings for the diff tool used to show file changes.
    public var diff: DiffToolSettings
    /// Settings for the agent CLI executables.
    public var agents: AgentToolSettings

    /// Creates tool settings from the given components, each defaulting to its own defaults.
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

    /// Decodes tool settings, substituting defaults for any missing component.
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

/// Settings controlling which editor executables YAAW prefers when opening files.
public struct EditorToolSettings: Codable, Equatable, Sendable {
    /// The editor executable names to try, in order of preference.
    public var preferred: [String]

    /// Creates editor settings, defaulting to `nvim`, `vim`, then `vi`.
    public init(preferred: [String] = ["nvim", "vim", "vi"]) {
        self.preferred = preferred
    }

    /// Decodes editor settings, defaulting to `nvim`, `vim`, then `vi` when absent.
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

/// Settings controlling which git UI executable YAAW launches.
public struct GitToolSettings: Codable, Equatable, Sendable {
    /// The preferred git UI executable name.
    public var preferred: String

    /// Creates git settings, defaulting to `lazygit`.
    public init(preferred: String = "lazygit") {
        self.preferred = preferred
    }

    /// Decodes git settings, defaulting to `lazygit` when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preferred = try container.decodeIfPresent(String.self, forKey: .preferred) ?? "lazygit"
    }

    internal func validated() -> GitToolSettings {
        let name = preferred.trimmed
        return GitToolSettings(preferred: name.isEmpty ? "lazygit" : name)
    }
}

/// Settings controlling the command used to show diffs when no richer tool applies.
public struct DiffToolSettings: Codable, Equatable, Sendable {
    /// The fallback diff command and its arguments.
    public var fallback: [String]

    /// Creates diff settings, defaulting to `git diff`.
    public init(fallback: [String] = ["git", "diff"]) {
        self.fallback = fallback
    }

    /// Decodes diff settings, defaulting to `git diff` when absent.
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

/// The executable names YAAW invokes for each supported agent CLI family.
public struct AgentToolSettings: Codable, Equatable, Sendable {
    /// The executable name for the `codex` CLI.
    public var codex: String
    /// The executable name for the `claude` CLI.
    public var claude: String
    /// The executable name for the `opencode` CLI.
    public var opencode: String
    /// The executable name for the `copilot` CLI.
    public var copilot: String

    /// Creates agent settings, defaulting each CLI to its conventional executable name.
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

    /// Decodes agent settings, defaulting each CLI to its conventional name when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codex = try container.decodeIfPresent(String.self, forKey: .codex) ?? "codex"
        self.claude = try container.decodeIfPresent(String.self, forKey: .claude) ?? "claude"
        self.opencode = try container.decodeIfPresent(String.self, forKey: .opencode) ?? "opencode"
        self.copilot = try container.decodeIfPresent(String.self, forKey: .copilot) ?? "copilot"
    }

    /// Returns the configured executable name for the given agent CLI family.
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

    /// Sets the executable name for the given agent CLI family.
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

/// The default way the file browser opens Markdown and HTML files.
public enum FileBrowserMarkdownAndHTMLDefault: String, CaseIterable, Codable, Equatable, Sendable {
    /// Open the file in the browser preview pane.
    case browserPreview
    /// Open the file in the built-in editor.
    case editor

    /// The user-facing name for the default option.
    public var displayName: String {
        switch self {
        case .browserPreview:
            "Browser preview"
        case .editor:
            "Built-in editor"
        }
    }
}

/// Settings controlling file browser behavior.
public struct FileBrowserSettings: Codable, Equatable, Sendable {
    /// How Markdown and HTML files are opened by default.
    public var markdownAndHTMLDefault: FileBrowserMarkdownAndHTMLDefault

    /// Creates file browser settings, defaulting Markdown/HTML to the browser preview.
    public init(
        markdownAndHTMLDefault: FileBrowserMarkdownAndHTMLDefault = .browserPreview
    ) {
        self.markdownAndHTMLDefault = markdownAndHTMLDefault
    }

    /// Decodes file browser settings, defaulting to the browser preview when absent or unknown.
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

/// Settings controlling which paths the file index skips while scanning a project.
public struct FileIndexingSettings: Codable, Equatable, Sendable {
    /// The directory and path names excluded from indexing.
    public var ignoreRules: [String]

    /// Creates file indexing settings, defaulting to ``defaultIgnoreRules``.
    public init(ignoreRules: [String] = Self.defaultIgnoreRules) {
        self.ignoreRules = ignoreRules
    }

    /// Decodes file indexing settings, defaulting to ``defaultIgnoreRules`` when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ignoreRules =
            try container.decodeIfPresent([String].self, forKey: .ignoreRules)
            ?? Self.defaultIgnoreRules
    }

    /// The default set of directory and path names excluded from indexing.
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
