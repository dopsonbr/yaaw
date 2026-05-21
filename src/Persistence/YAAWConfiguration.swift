import Foundation
import Yams

public struct YAAWConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var agent: AgentSettings
    public var theme: ThemeSettings
    public var keyboardShortcuts: KeyboardShortcutSettings
    public var tools: ToolSettings
    public var fileIndexing: FileIndexingSettings

    public init(
        version: Int = 1,
        agent: AgentSettings = AgentSettings(),
        theme: ThemeSettings = ThemeSettings(),
        keyboardShortcuts: KeyboardShortcutSettings = KeyboardShortcutSettings(),
        tools: ToolSettings = ToolSettings(),
        fileIndexing: FileIndexingSettings = FileIndexingSettings()
    ) {
        self.version = version
        self.agent = agent
        self.theme = theme
        self.keyboardShortcuts = keyboardShortcuts
        self.tools = tools
        self.fileIndexing = fileIndexing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.agent = try container.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? AgentSettings()
        self.theme = try container.decodeIfPresent(ThemeSettings.self, forKey: .theme) ?? ThemeSettings()
        self.keyboardShortcuts = try container.decodeIfPresent(
            KeyboardShortcutSettings.self,
            forKey: .keyboardShortcuts
        ) ?? KeyboardShortcutSettings()
        self.tools = try container.decodeIfPresent(ToolSettings.self, forKey: .tools) ?? ToolSettings()
        self.fileIndexing = try container.decodeIfPresent(
            FileIndexingSettings.self,
            forKey: .fileIndexing
        ) ?? FileIndexingSettings()
    }

    public static let defaultIgnoreRules = FileIndexingSettings.defaultIgnoreRules

    public var themeName: String {
        theme.active
    }

    public var ignoreRules: [String] {
        fileIndexing.ignoreRules
    }

    public var defaultAgentCLI: AgentCLIKind {
        agent.default
    }

    public func agentExecutableName(for kind: AgentCLIKind) -> String {
        tools.agents.executableName(for: kind)
    }

    public func shortcut(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition {
        keyboardShortcuts.definition(for: action)
    }

    public func validated() -> YAAWConfiguration {
        var configuration = self
        configuration.version = max(configuration.version, 1)
        configuration.agent = configuration.agent.validated()
        configuration.theme = configuration.theme.validated()
        configuration.keyboardShortcuts = configuration.keyboardShortcuts.validated()
        configuration.tools = configuration.tools.validated()
        configuration.fileIndexing = configuration.fileIndexing.mergingMissingDefaultIgnoreRules()
        return configuration
    }
}

public struct AgentSettings: Codable, Equatable, Sendable {
    public var `default`: AgentCLIKind

    public init(default: AgentCLIKind = .codex) {
        self.default = `default`
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.default = try container.decodeIfPresent(AgentCLIKind.self, forKey: .default) ?? .codex
    }

    fileprivate func validated() -> AgentSettings {
        self
    }
}

public struct ThemeSettings: Codable, Equatable, Sendable {
    public var active: String
    public var custom: [String: String]

    public init(active: String = "dracula", custom: [String: String] = [:]) {
        self.active = active
        self.custom = custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try container.decodeIfPresent(String.self, forKey: .active) ?? "dracula"
        self.custom = try container.decodeIfPresent([String: String].self, forKey: .custom) ?? [:]
    }

    fileprivate func validated() -> ThemeSettings {
        var settings = self
        settings.active = "dracula"
        return settings
    }
}

public enum KeyboardShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case toggleBottomTerminal
    case navigateBack
    case navigateForward
    case previousRightPanelMode
    case nextRightPanelMode
    case toggleSidebar
    case toggleRightPanel

    public var id: String {
        rawValue
    }
}

public enum KeyboardShortcutModifier: String, Codable, CaseIterable, Equatable, Sendable {
    case command
    case shift
    case option
    case control
}

public struct KeyboardShortcutDefinition: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [KeyboardShortcutModifier]

    public init(key: String, modifiers: [KeyboardShortcutModifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.modifiers = try container.decodeIfPresent(
            [KeyboardShortcutModifier].self,
            forKey: .modifiers
        ) ?? []
    }

    public var isValid: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).count == 1 && !modifiers.isEmpty
    }

    fileprivate func validated(fallback: KeyboardShortcutDefinition) -> KeyboardShortcutDefinition {
        isValid ? self : fallback
    }
}

public struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    public var toggleBottomTerminal: KeyboardShortcutDefinition
    public var navigateBack: KeyboardShortcutDefinition
    public var navigateForward: KeyboardShortcutDefinition
    public var previousRightPanelMode: KeyboardShortcutDefinition
    public var nextRightPanelMode: KeyboardShortcutDefinition
    public var toggleSidebar: KeyboardShortcutDefinition
    public var toggleRightPanel: KeyboardShortcutDefinition

    public init(
        toggleBottomTerminal: KeyboardShortcutDefinition = Self.defaultToggleBottomTerminal,
        navigateBack: KeyboardShortcutDefinition = Self.defaultNavigateBack,
        navigateForward: KeyboardShortcutDefinition = Self.defaultNavigateForward,
        previousRightPanelMode: KeyboardShortcutDefinition = Self.defaultPreviousRightPanelMode,
        nextRightPanelMode: KeyboardShortcutDefinition = Self.defaultNextRightPanelMode,
        toggleSidebar: KeyboardShortcutDefinition = Self.defaultToggleSidebar,
        toggleRightPanel: KeyboardShortcutDefinition = Self.defaultToggleRightPanel
    ) {
        self.toggleBottomTerminal = toggleBottomTerminal
        self.navigateBack = navigateBack
        self.navigateForward = navigateForward
        self.previousRightPanelMode = previousRightPanelMode
        self.nextRightPanelMode = nextRightPanelMode
        self.toggleSidebar = toggleSidebar
        self.toggleRightPanel = toggleRightPanel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toggleBottomTerminal = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .toggleBottomTerminal
        ) ?? Self.defaultToggleBottomTerminal
        self.navigateBack = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .navigateBack
        ) ?? Self.defaultNavigateBack
        self.navigateForward = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .navigateForward
        ) ?? Self.defaultNavigateForward
        self.previousRightPanelMode = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .previousRightPanelMode
        ) ?? Self.defaultPreviousRightPanelMode
        self.nextRightPanelMode = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .nextRightPanelMode
        ) ?? Self.defaultNextRightPanelMode
        self.toggleSidebar = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .toggleSidebar
        ) ?? Self.defaultToggleSidebar
        self.toggleRightPanel = try container.decodeIfPresent(
            KeyboardShortcutDefinition.self,
            forKey: .toggleRightPanel
        ) ?? Self.defaultToggleRightPanel
    }

    public func definition(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition {
        switch action {
        case .toggleBottomTerminal:
            toggleBottomTerminal
        case .navigateBack:
            navigateBack
        case .navigateForward:
            navigateForward
        case .previousRightPanelMode:
            previousRightPanelMode
        case .nextRightPanelMode:
            nextRightPanelMode
        case .toggleSidebar:
            toggleSidebar
        case .toggleRightPanel:
            toggleRightPanel
        }
    }

    fileprivate func validated() -> KeyboardShortcutSettings {
        KeyboardShortcutSettings(
            toggleBottomTerminal: toggleBottomTerminal.validated(fallback: Self.defaultToggleBottomTerminal),
            navigateBack: navigateBack.validated(fallback: Self.defaultNavigateBack),
            navigateForward: navigateForward.validated(fallback: Self.defaultNavigateForward),
            previousRightPanelMode: previousRightPanelMode.validated(fallback: Self.defaultPreviousRightPanelMode),
            nextRightPanelMode: nextRightPanelMode.validated(fallback: Self.defaultNextRightPanelMode),
            toggleSidebar: toggleSidebar.validated(fallback: Self.defaultToggleSidebar),
            toggleRightPanel: toggleRightPanel.validated(fallback: Self.defaultToggleRightPanel)
        )
    }

    public static let defaultToggleBottomTerminal = KeyboardShortcutDefinition(key: "j", modifiers: [.command])
    public static let defaultNavigateBack = KeyboardShortcutDefinition(key: "[", modifiers: [.command])
    public static let defaultNavigateForward = KeyboardShortcutDefinition(key: "]", modifiers: [.command])
    public static let defaultPreviousRightPanelMode = KeyboardShortcutDefinition(key: "[", modifiers: [.command, .shift])
    public static let defaultNextRightPanelMode = KeyboardShortcutDefinition(key: "]", modifiers: [.command, .shift])
    public static let defaultToggleSidebar = KeyboardShortcutDefinition(key: "s", modifiers: [.command, .option])
    public static let defaultToggleRightPanel = KeyboardShortcutDefinition(key: "r", modifiers: [.command, .option])
}

public struct ToolSettings: Codable, Equatable, Sendable {
    public var editors: EditorToolSettings
    public var git: GitToolSettings
    public var diff: DiffToolSettings
    public var agents: AgentToolSettings

    public init(
        editors: EditorToolSettings = EditorToolSettings(),
        git: GitToolSettings = GitToolSettings(),
        diff: DiffToolSettings = DiffToolSettings(),
        agents: AgentToolSettings = AgentToolSettings()
    ) {
        self.editors = editors
        self.git = git
        self.diff = diff
        self.agents = agents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.editors = try container.decodeIfPresent(EditorToolSettings.self, forKey: .editors) ?? EditorToolSettings()
        self.git = try container.decodeIfPresent(GitToolSettings.self, forKey: .git) ?? GitToolSettings()
        self.diff = try container.decodeIfPresent(DiffToolSettings.self, forKey: .diff) ?? DiffToolSettings()
        self.agents = try container.decodeIfPresent(AgentToolSettings.self, forKey: .agents) ?? AgentToolSettings()
    }

    fileprivate func validated() -> ToolSettings {
        ToolSettings(
            editors: editors.validated(),
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
        self.preferred = try container.decodeIfPresent([String].self, forKey: .preferred) ?? ["nvim", "vim", "vi"]
    }

    fileprivate func validated() -> EditorToolSettings {
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

    fileprivate func validated() -> GitToolSettings {
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
        self.fallback = try container.decodeIfPresent([String].self, forKey: .fallback) ?? ["git", "diff"]
    }

    fileprivate func validated() -> DiffToolSettings {
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

    fileprivate func validated() -> AgentToolSettings {
        AgentToolSettings(
            codex: codex.nonBlankOr("codex"),
            claude: claude.nonBlankOr("claude"),
            opencode: opencode.nonBlankOr("opencode"),
            copilot: copilot.nonBlankOr("copilot")
        )
    }
}

public struct FileIndexingSettings: Codable, Equatable, Sendable {
    public var ignoreRules: [String]

    public init(ignoreRules: [String] = Self.defaultIgnoreRules) {
        self.ignoreRules = ignoreRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ignoreRules = try container.decodeIfPresent([String].self, forKey: .ignoreRules) ?? Self.defaultIgnoreRules
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
        "Music",
        "Movies",
        "Pictures",
        "Photos Library.photoslibrary"
    ]

    fileprivate func mergingMissingDefaultIgnoreRules() -> FileIndexingSettings {
        var mergedRules = ignoreRules.nonBlankValues
        let existingRules = Set(mergedRules.map(FilePathNormalizer.normalizedRule))
        for rule in Self.defaultIgnoreRules where !existingRules.contains(FilePathNormalizer.normalizedRule(rule)) {
            mergedRules.append(rule)
        }
        return FileIndexingSettings(ignoreRules: mergedRules)
    }
}

public final class YAMLConfigurationStore {
    private let path: URL
    private let diagnosticRecorder: DiagnosticEventRecording

    public init(
        path: URL,
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared
    ) {
        self.path = path
        self.diagnosticRecorder = diagnosticRecorder
    }

    public static func defaultPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("settings.yaml")
    }

    public func load() -> YAAWConfiguration {
        do {
            guard FileManager.default.fileExists(atPath: path.path) else {
                let configuration = YAAWConfiguration()
                try save(configuration)
                return configuration
            }
            let text = try String(contentsOf: path, encoding: .utf8)
            return try YAMLDecoder().decode(YAAWConfiguration.self, from: text).validated()
        } catch {
            diagnosticRecorder.record(
                DiagnosticEvent(
                    category: "Configuration",
                    name: "settings_yaml_recovered",
                    metadata: [
                        "path": path.path,
                        "error": String(describing: error)
                    ]
                )
            )
            return YAAWConfiguration()
        }
    }

    public func save(_ configuration: YAAWConfiguration) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Self.render(configuration.validated()).data(using: .utf8) ?? Data()
        let temporaryPath = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporaryPath, options: .atomic)
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: temporaryPath)
        } else {
            try FileManager.default.moveItem(at: temporaryPath, to: path)
        }
    }

    public static func render(_ configuration: YAAWConfiguration = YAAWConfiguration()) -> String {
        let configuration = configuration.validated()
        return """
        # YAAW settings.
        # Defaults are shown inline. Keys marked "not changeable yet" are reserved for future expansion.

        version: \(configuration.version)

        agent:
          # default: codex
          # active now: used when a flow needs a default CLI choice.
          default: \(configuration.agent.default.rawValue)

        theme:
          # default: dracula
          # active now: only dracula is implemented.
          active: \(configuration.theme.active)
          # not changeable yet: custom palettes are reserved for future expansion.
          custom: {}

        keyboardShortcuts:
        \(renderShortcut("toggleBottomTerminal", configuration.keyboardShortcuts.toggleBottomTerminal, defaultText: "command+j", activeComment: "active now."))
        \(renderShortcut("navigateBack", configuration.keyboardShortcuts.navigateBack, defaultText: "command+["))
        \(renderShortcut("navigateForward", configuration.keyboardShortcuts.navigateForward, defaultText: "command+]"))
        \(renderShortcut("previousRightPanelMode", configuration.keyboardShortcuts.previousRightPanelMode, defaultText: "command+shift+["))
        \(renderShortcut("nextRightPanelMode", configuration.keyboardShortcuts.nextRightPanelMode, defaultText: "command+shift+]"))
        \(renderShortcut("toggleSidebar", configuration.keyboardShortcuts.toggleSidebar, defaultText: "command+option+s"))
        \(renderShortcut("toggleRightPanel", configuration.keyboardShortcuts.toggleRightPanel, defaultText: "command+option+r"))

        tools:
          editors:
            # default: [nvim, vim, vi]
            # active now: first available executable is used.
            preferred: \(inlineList(configuration.tools.editors.preferred))
          git:
            # default: lazygit
            # active now.
            preferred: \(yamlScalar(configuration.tools.git.preferred))
          diff:
            # default: git diff
            # active now when lazygit is unavailable.
            fallback: \(inlineList(configuration.tools.diff.fallback))
          agents:
            # active now: command names used for PATH lookup.
            codex: \(yamlScalar(configuration.tools.agents.codex))
            claude: \(yamlScalar(configuration.tools.agents.claude))
            opencode: \(yamlScalar(configuration.tools.agents.opencode))
            copilot: \(yamlScalar(configuration.tools.agents.copilot))

        fileIndexing:
          # active now.
          ignoreRules:
        \(blockList(configuration.fileIndexing.ignoreRules, indent: 4))
        """
    }

    private static func renderShortcut(
        _ name: String,
        _ shortcut: KeyboardShortcutDefinition,
        defaultText: String,
        activeComment: String? = nil
    ) -> String {
        let activeLine = activeComment.map { "\n    # \($0)" } ?? ""
        return """
          \(name):
            # default: \(defaultText)\(activeLine)
            key: \(yamlScalar(shortcut.key))
            modifiers: \(inlineList(shortcut.modifiers.map(\.rawValue)))
        """
    }

    private static func inlineList(_ values: [String]) -> String {
        "[\(values.map(yamlScalar).joined(separator: ", "))]"
    }

    private static func blockList(_ values: [String], indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        return values.map { "\(prefix)- \(yamlScalar($0))" }.joined(separator: "\n")
    }

    private static func yamlScalar(_ value: String) -> String {
        let plainPattern = #"^[A-Za-z0-9_./-]+$"#
        if value.range(of: plainPattern, options: .regularExpression) != nil,
           !["true", "false", "null"].contains(value.lowercased()) {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

private extension Array where Element == String {
    var nonBlankValues: [String] {
        map(\.trimmed).filter { !$0.isEmpty }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nonBlankOr(_ fallback: String) -> String {
        let value = trimmed
        return value.isEmpty ? fallback : value
    }
}
