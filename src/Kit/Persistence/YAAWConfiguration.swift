import Foundation

public struct YAAWConfiguration: Codable, Equatable, Sendable {
    /// Current settings-*schema* version. Bumped when the shape of the config
    /// changes in a way that needs an in-memory migration on load. Distinct from
    /// ``version`` (the user-facing config-file version).
    public static let currentSchemaVersion = 1

    public var version: Int
    /// Schema version this snapshot was written against; drives the migration
    /// ladder in ``validated(diagnosticRecorder:)``. Files written before the
    /// rewrite have no `schemaVersion` key and decode as `0` (legacy), which the
    /// ladder upgrades to ``currentSchemaVersion``.
    public var schemaVersion: Int
    public var agent: AgentSettings
    public var projects: ProjectSettings
    public var theme: ThemeSettings
    public var icons: IconSettings
    public var fonts: FontSettings
    public var keyboardShortcuts: KeyboardShortcutSettings
    public var tools: ToolSettings
    public var fileBrowser: FileBrowserSettings
    public var fileIndexing: FileIndexingSettings

    public init(
        version: Int = 1,
        schemaVersion: Int = YAAWConfiguration.currentSchemaVersion,
        agent: AgentSettings = AgentSettings(),
        projects: ProjectSettings = ProjectSettings(),
        theme: ThemeSettings = ThemeSettings(),
        icons: IconSettings = IconSettings(),
        fonts: FontSettings = FontSettings(),
        keyboardShortcuts: KeyboardShortcutSettings = KeyboardShortcutSettings(),
        tools: ToolSettings = ToolSettings(),
        fileBrowser: FileBrowserSettings = FileBrowserSettings(),
        fileIndexing: FileIndexingSettings = FileIndexingSettings()
    ) {
        self.version = version
        self.schemaVersion = schemaVersion
        self.agent = agent
        self.projects = projects
        self.theme = theme
        self.icons = icons
        self.fonts = fonts
        self.keyboardShortcuts = keyboardShortcuts
        self.tools = tools
        self.fileBrowser = fileBrowser
        self.fileIndexing = fileIndexing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // Missing key => a pre-rewrite config; decode as legacy schema 0 so the
        // migration ladder in `validated()` upgrades it.
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.agent =
            try container.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? AgentSettings()
        self.projects =
            try container.decodeIfPresent(ProjectSettings.self, forKey: .projects)
            ?? ProjectSettings()
        self.theme =
            try container.decodeIfPresent(ThemeSettings.self, forKey: .theme) ?? ThemeSettings()
        self.icons =
            try container.decodeIfPresent(IconSettings.self, forKey: .icons) ?? IconSettings()
        self.fonts =
            try container.decodeIfPresent(FontSettings.self, forKey: .fonts) ?? FontSettings()
        self.keyboardShortcuts =
            try container.decodeIfPresent(
                KeyboardShortcutSettings.self,
                forKey: .keyboardShortcuts
            ) ?? KeyboardShortcutSettings()
        self.tools =
            try container.decodeIfPresent(ToolSettings.self, forKey: .tools) ?? ToolSettings()
        self.fileBrowser =
            try container.decodeIfPresent(FileBrowserSettings.self, forKey: .fileBrowser)
            ?? FileBrowserSettings()
        self.fileIndexing =
            try container.decodeIfPresent(
                FileIndexingSettings.self,
                forKey: .fileIndexing
            ) ?? FileIndexingSettings()
    }

    public static let defaultIgnoreRules = FileIndexingSettings.defaultIgnoreRules

    public var themeName: String {
        theme.active
    }

    public func resolvedTheme(systemAppearanceIsDark: Bool) -> ThemeDefinition {
        theme.resolvedTheme(systemAppearanceIsDark: systemAppearanceIsDark)
    }

    public var ignoreRules: [String] {
        fileIndexing.ignoreRules
    }

    public var fileIconPack: FileIconPack {
        icons.resolvedFileBrowserPack
    }

    public var defaultAgentCLI: AgentCLIKind {
        agent.default
    }

    public func agentExecutableName(for kind: AgentCLIKind) -> String {
        tools.agents.executableName(for: kind)
    }

    public func defaultLaunchOptions(for kind: AgentCLIKind) -> AgentLaunchOptions {
        let defaults = agent.launchDefaults.defaults(for: kind)
        return AgentLaunchOptions(
            executableName: agentExecutableName(for: kind),
            permissionModeID: defaults.permissionModeID,
            additionalArguments: defaults.additionalArguments
        )
    }

    public func shortcut(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition {
        keyboardShortcuts.definition(for: action)
    }

    public func validated(diagnosticRecorder: DiagnosticEventRecording? = nil) -> YAAWConfiguration
    {
        var configuration = self.migratedToCurrentSchema(diagnosticRecorder: diagnosticRecorder)
        configuration.version = max(configuration.version, 1)
        configuration.agent = configuration.agent.validated()
        configuration.projects = configuration.projects.validated()
        configuration.theme = configuration.theme.validated(diagnosticRecorder: diagnosticRecorder)
        configuration.icons = configuration.icons.validated(diagnosticRecorder: diagnosticRecorder)
        configuration.fonts = configuration.fonts.validated()
        configuration.keyboardShortcuts = configuration.keyboardShortcuts.validated()
        let duplicateActions = configuration.keyboardShortcuts.duplicateActions()
        if !duplicateActions.isEmpty {
            diagnosticRecorder?.record(
                DiagnosticEvent(
                    category: "Configuration",
                    name: "duplicate_keyboard_shortcuts",
                    metadata: [
                        "actions": duplicateActions.map(\.rawValue).sorted().joined(separator: ",")
                    ]
                )
            )
        }
        configuration.tools = configuration.tools.validated()
        configuration.fileBrowser = configuration.fileBrowser.validated()
        return configuration
    }

    /// Upgrades a decoded snapshot to ``currentSchemaVersion``, applying each
    /// ladder step in order. The hook exists so future schema changes have a
    /// single place to transform old snapshots; the 0 → 1 step is currently a
    /// pure version stamp (no field reshaping needed yet). Snapshots already at
    /// or beyond the current version are returned unchanged.
    private func migratedToCurrentSchema(
        diagnosticRecorder: DiagnosticEventRecording?
    ) -> YAAWConfiguration {
        guard schemaVersion < Self.currentSchemaVersion else { return self }
        var configuration = self
        if configuration.schemaVersion < 1 {
            // 0 -> 1: introduce `schemaVersion`. No field reshaping.
            configuration.schemaVersion = 1
        }
        diagnosticRecorder?.record(
            DiagnosticEvent(
                category: "Configuration",
                name: "config_schema_migrated",
                metadata: [
                    "from": String(schemaVersion),
                    "to": String(configuration.schemaVersion),
                ]
            )
        )
        return configuration
    }
}

public struct AgentSettings: Codable, Equatable, Sendable {
    public var `default`: AgentCLIKind
    public var launchDefaults: AgentLaunchDefaultsSettings

    public init(
        default: AgentCLIKind = .codex,
        launchDefaults: AgentLaunchDefaultsSettings = AgentLaunchDefaultsSettings()
    ) {
        self.default = `default`
        self.launchDefaults = launchDefaults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.default = try container.decodeIfPresent(AgentCLIKind.self, forKey: .default) ?? .codex
        self.launchDefaults =
            try container.decodeIfPresent(
                AgentLaunchDefaultsSettings.self,
                forKey: .launchDefaults
            ) ?? AgentLaunchDefaultsSettings()
    }

    internal func validated() -> AgentSettings {
        AgentSettings(
            default: `default`,
            launchDefaults: launchDefaults.validated())
    }
}

public struct AgentLaunchDefaultSettings: Codable, Equatable, Sendable {
    public var permissionModeID: String?
    public var additionalArguments: [String]

    public init(permissionModeID: String? = nil, additionalArguments: [String] = []) {
        self.permissionModeID = permissionModeID?.configurationNilIfBlank
        self.additionalArguments = additionalArguments.map(\.trimmed).filter { !$0.isEmpty }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.permissionModeID =
            try container.decodeIfPresent(String.self, forKey: .permissionModeID)?
            .configurationNilIfBlank
        self.additionalArguments =
            try container.decodeIfPresent([String].self, forKey: .additionalArguments) ?? []
    }

    internal func validated() -> AgentLaunchDefaultSettings {
        AgentLaunchDefaultSettings(
            permissionModeID: permissionModeID,
            additionalArguments: additionalArguments
        )
    }
}

public struct AgentLaunchDefaultsSettings: Codable, Equatable, Sendable {
    public var codex: AgentLaunchDefaultSettings
    public var claude: AgentLaunchDefaultSettings
    public var opencode: AgentLaunchDefaultSettings
    public var copilot: AgentLaunchDefaultSettings

    public init(
        codex: AgentLaunchDefaultSettings = AgentLaunchDefaultSettings(),
        claude: AgentLaunchDefaultSettings = AgentLaunchDefaultSettings(),
        opencode: AgentLaunchDefaultSettings = AgentLaunchDefaultSettings(),
        copilot: AgentLaunchDefaultSettings = AgentLaunchDefaultSettings()
    ) {
        self.codex = codex
        self.claude = claude
        self.opencode = opencode
        self.copilot = copilot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codex =
            try container.decodeIfPresent(AgentLaunchDefaultSettings.self, forKey: .codex)
            ?? AgentLaunchDefaultSettings()
        self.claude =
            try container.decodeIfPresent(AgentLaunchDefaultSettings.self, forKey: .claude)
            ?? AgentLaunchDefaultSettings()
        self.opencode =
            try container.decodeIfPresent(AgentLaunchDefaultSettings.self, forKey: .opencode)
            ?? AgentLaunchDefaultSettings()
        self.copilot =
            try container.decodeIfPresent(AgentLaunchDefaultSettings.self, forKey: .copilot)
            ?? AgentLaunchDefaultSettings()
    }

    public func defaults(for kind: AgentCLIKind) -> AgentLaunchDefaultSettings {
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

    public mutating func setDefaults(_ defaults: AgentLaunchDefaultSettings, for kind: AgentCLIKind)
    {
        switch kind {
        case .codex:
            codex = defaults
        case .claude:
            claude = defaults
        case .opencode:
            opencode = defaults
        case .copilot:
            copilot = defaults
        }
    }

    internal func validated() -> AgentLaunchDefaultsSettings {
        AgentLaunchDefaultsSettings(
            codex: codex.validated(),
            claude: claude.validated(),
            opencode: opencode.validated(),
            copilot: copilot.validated()
        )
    }
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    public static let defaultGlobalChatsDirectory = "~/yaaw"

    public var globalChatsDirectory: String

    public init(globalChatsDirectory: String = Self.defaultGlobalChatsDirectory) {
        self.globalChatsDirectory = globalChatsDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.globalChatsDirectory =
            try container.decodeIfPresent(String.self, forKey: .globalChatsDirectory)
            ?? Self.defaultGlobalChatsDirectory
    }

    public func resolvedGlobalChatsDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let value = globalChatsDirectory.trimmed.nonBlankOr(Self.defaultGlobalChatsDirectory)
        if value == "~" {
            return homeDirectory
        }
        if value.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(
                String(value.dropFirst(2)), isDirectory: true)
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(value, isDirectory: true)
    }

    internal func validated() -> ProjectSettings {
        ProjectSettings(
            globalChatsDirectory: globalChatsDirectory.nonBlankOr(Self.defaultGlobalChatsDirectory))
    }
}

/// How the active theme is chosen: follow the macOS appearance with a
/// light/dark pairing, or pin one fixed theme.
public enum ThemeSelectionMode: Equatable, Sendable {
    case system
    case fixed(String)
}

public struct ThemeSettings: Codable, Equatable, Sendable {
    /// Sentinel `active` value meaning "follow the macOS appearance".
    public static let systemActiveID = "system"

    public var active: String
    /// Theme used by system mode in the light appearance.
    public var light: String
    /// Theme used by system mode in the dark appearance.
    public var dark: String
    public var custom: [String: String]

    public init(
        active: String = ThemeSettings.systemActiveID,
        light: String = ThemeCatalog.defaultLightID,
        dark: String = ThemeCatalog.defaultDarkID,
        custom: [String: String] = [:]
    ) {
        self.active = active
        self.light = light
        self.dark = dark
        self.custom = custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active =
            try container.decodeIfPresent(String.self, forKey: .active)
            ?? ThemeSettings.systemActiveID
        self.light =
            try container.decodeIfPresent(String.self, forKey: .light)
            ?? ThemeCatalog.defaultLightID
        self.dark =
            try container.decodeIfPresent(String.self, forKey: .dark)
            ?? ThemeCatalog.defaultDarkID
        self.custom = try container.decodeIfPresent([String: String].self, forKey: .custom) ?? [:]
    }

    public var mode: ThemeSelectionMode {
        active.trimmed.lowercased() == Self.systemActiveID ? .system : .fixed(active)
    }

    public func resolvedTheme(systemAppearanceIsDark: Bool) -> ThemeDefinition {
        switch mode {
        case .system:
            let pairedID = systemAppearanceIsDark ? dark : light
            let fallbackID =
                systemAppearanceIsDark ? ThemeCatalog.defaultDarkID : ThemeCatalog.defaultLightID
            return ThemeCatalog.theme(id: pairedID) ?? ThemeCatalog.theme(id: fallbackID)!
        case .fixed(let id):
            return ThemeCatalog.theme(id: id) ?? ThemeCatalog.defaultTheme
        }
    }

    internal func validated(diagnosticRecorder: DiagnosticEventRecording?) -> ThemeSettings {
        let validatedLight = validatedSlot(
            light, slot: "light", fallback: ThemeCatalog.defaultLightID,
            diagnosticRecorder: diagnosticRecorder)
        let validatedDark = validatedSlot(
            dark, slot: "dark", fallback: ThemeCatalog.defaultDarkID,
            diagnosticRecorder: diagnosticRecorder)

        let trimmedThemeID = active.trimmed.lowercased()
        if trimmedThemeID == Self.systemActiveID {
            return ThemeSettings(
                active: Self.systemActiveID, light: validatedLight, dark: validatedDark,
                custom: custom)
        }
        guard let theme = ThemeCatalog.theme(id: trimmedThemeID) else {
            if !trimmedThemeID.isEmpty {
                diagnosticRecorder?.record(
                    DiagnosticEvent(
                        category: "Configuration",
                        name: "unsupported_theme",
                        metadata: [
                            "requested": trimmedThemeID,
                            "fallback": Self.systemActiveID,
                        ]
                    )
                )
            }
            return ThemeSettings(
                active: Self.systemActiveID, light: validatedLight, dark: validatedDark,
                custom: custom)
        }
        return ThemeSettings(
            active: theme.id, light: validatedLight, dark: validatedDark, custom: custom)
    }

    private func validatedSlot(
        _ id: String,
        slot: String,
        fallback: String,
        diagnosticRecorder: DiagnosticEventRecording?
    ) -> String {
        let trimmedID = id.trimmed.lowercased()
        if let theme = ThemeCatalog.theme(id: trimmedID) {
            return theme.id
        }
        if !trimmedID.isEmpty {
            diagnosticRecorder?.record(
                DiagnosticEvent(
                    category: "Configuration",
                    name: "unsupported_theme",
                    metadata: [
                        "requested": trimmedID,
                        "fallback": fallback,
                        "slot": slot,
                    ]
                )
            )
        }
        return fallback
    }
}

public struct IconSettings: Codable, Equatable, Sendable {
    public var fileBrowserPack: String

    public init(fileBrowserPack: String = FileIconPack.fallback.rawValue) {
        self.fileBrowserPack = fileBrowserPack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileBrowserPack =
            try container.decodeIfPresent(String.self, forKey: .fileBrowserPack)
            ?? FileIconPack.fallback.rawValue
    }

    public var resolvedFileBrowserPack: FileIconPack {
        FileIconPack(rawValue: fileBrowserPack.trimmed) ?? .fallback
    }

    internal func validated(diagnosticRecorder: DiagnosticEventRecording?) -> IconSettings {
        let trimmedPack = fileBrowserPack.trimmed
        guard FileIconPack(rawValue: trimmedPack) != nil else {
            if !trimmedPack.isEmpty {
                diagnosticRecorder?.record(
                    DiagnosticEvent(
                        category: "Configuration",
                        name: "unsupported_icon_pack",
                        metadata: [
                            "requested": trimmedPack,
                            "fallback": FileIconPack.fallback.rawValue,
                        ]
                    )
                )
            }
            return IconSettings(fileBrowserPack: FileIconPack.fallback.rawValue)
        }
        return IconSettings(fileBrowserPack: trimmedPack)
    }
}

public struct FontSettings: Codable, Equatable, Sendable {
    /// Sentinel family meaning "use the interface font/size" for the file browser.
    public static let inheritFamily = "inherit"

    public var interfaceFamily: String
    public var interfaceSize: Double
    public var editorFamily: String
    public var editorSize: Double
    public var terminalFamily: String
    public var terminalSize: Double
    /// File browser list font. `inherit` (the default) means follow the interface font.
    public var fileBrowserFamily: String
    /// File browser list size. `0` means inherit the interface size.
    public var fileBrowserSize: Double
    /// Whether editor and terminal text shapes font ligatures (when the font has them).
    public var ligatures: Bool

    public init(
        interfaceFamily: String = "system",
        interfaceSize: Double = 13,
        editorFamily: String = "JetBrains Mono",
        editorSize: Double = 13,
        terminalFamily: String = "JetBrains Mono",
        terminalSize: Double = 15,
        fileBrowserFamily: String = FontSettings.inheritFamily,
        fileBrowserSize: Double = 0,
        ligatures: Bool = true
    ) {
        self.interfaceFamily = interfaceFamily
        self.interfaceSize = interfaceSize
        self.editorFamily = editorFamily
        self.editorSize = editorSize
        self.terminalFamily = terminalFamily
        self.terminalSize = terminalSize
        self.fileBrowserFamily = fileBrowserFamily
        self.fileBrowserSize = fileBrowserSize
        self.ligatures = ligatures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.interfaceFamily =
            try container.decodeIfPresent(String.self, forKey: .interfaceFamily) ?? "system"
        self.interfaceSize =
            try container.decodeIfPresent(Double.self, forKey: .interfaceSize) ?? 13
        self.editorFamily =
            try container.decodeIfPresent(String.self, forKey: .editorFamily) ?? "JetBrains Mono"
        self.editorSize = try container.decodeIfPresent(Double.self, forKey: .editorSize) ?? 13
        self.terminalFamily =
            try container.decodeIfPresent(String.self, forKey: .terminalFamily) ?? "JetBrains Mono"
        self.terminalSize = try container.decodeIfPresent(Double.self, forKey: .terminalSize) ?? 15
        self.fileBrowserFamily =
            try container.decodeIfPresent(String.self, forKey: .fileBrowserFamily)
            ?? FontSettings.inheritFamily
        self.fileBrowserSize =
            try container.decodeIfPresent(Double.self, forKey: .fileBrowserSize) ?? 0
        self.ligatures = try container.decodeIfPresent(Bool.self, forKey: .ligatures) ?? true
    }

    internal func validated() -> FontSettings {
        FontSettings(
            interfaceFamily: interfaceFamily.nonBlankOr("system"),
            interfaceSize: interfaceSize.clampedFontSize(defaultValue: 13, minimum: 9, maximum: 28),
            editorFamily: editorFamily.nonBlankOr("system-monospace"),
            editorSize: editorSize.clampedFontSize(defaultValue: 13, minimum: 9, maximum: 28),
            terminalFamily: terminalFamily.trimmed,
            terminalSize: terminalSize.clampedFontSize(defaultValue: 15, minimum: 8, maximum: 32),
            fileBrowserFamily: fileBrowserFamily.nonBlankOr(FontSettings.inheritFamily),
            fileBrowserSize: fileBrowserSize > 0
                ? fileBrowserSize.clampedFontSize(defaultValue: 13, minimum: 9, maximum: 28)
                : 0,
            ligatures: ligatures
        )
    }
}
