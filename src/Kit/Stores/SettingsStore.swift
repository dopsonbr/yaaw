import Observation

/// Owns validated configuration, hot-reload, the live system appearance, the agent
/// CLI option catalog, and `resolvedTheme` against the live `systemAppearanceIsDark`.
/// `@MainActor @Observable`: views observe `configuration`/`systemAppearanceIsDark`
/// directly; the app's `SystemAppearanceObserver` pushes appearance via
/// ``updateSystemAppearance(isDark:)``.
@MainActor
@Observable
public final class SettingsStore {
    /// The current validated configuration loaded from `settings.yaml`.
    public private(set) var configuration: YAAWConfiguration
    /// Whether the live macOS appearance is dark, pushed in by the app layer.
    public private(set) var systemAppearanceIsDark: Bool
    /// The discovered per-CLI option catalog (permission presets, etc.).
    public private(set) var agentCLIOptionCatalog: AgentCLIOptionCatalog

    @ObservationIgnored private let environment: AppEnvironment

    init(context: StoreLoadContext) {
        self.environment = context.environment
        self.configuration = YAAWConfiguration().validated(
            diagnosticRecorder: context.environment.diagnosticRecorder)
        self.systemAppearanceIsDark = true
        self.agentCLIOptionCatalog = context.environment.agentCLIOptionCatalogService.loadCatalog()
    }

    /// Test/convenience seam: build a standalone settings store from explicit
    /// values (no snapshot needed — settings live in YAML, not the snapshot).
    public init(
        environment: AppEnvironment,
        configuration: YAAWConfiguration = YAAWConfiguration(),
        systemAppearanceIsDark: Bool = true
    ) {
        self.environment = environment
        self.configuration = configuration.validated(
            diagnosticRecorder: environment.diagnosticRecorder)
        self.systemAppearanceIsDark = systemAppearanceIsDark
        self.agentCLIOptionCatalog = environment.agentCLIOptionCatalogService.loadCatalog()
    }

    // MARK: - Computed

    /// The active theme, resolving the System pairing against the live macOS
    /// appearance pushed in by the app layer.
    public var resolvedTheme: ThemeDefinition {
        configuration.resolvedTheme(systemAppearanceIsDark: systemAppearanceIsDark)
    }

    /// The configured default agent CLI family for new threads.
    public var defaultAgentCLI: AgentCLIKind {
        configuration.defaultAgentCLI
    }

    // MARK: - Reads used by other stores / views

    /// The permission presets available for an agent CLI family, from the catalog.
    public func permissionModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode] {
        agentCLIOptionCatalog.permissionPresets(for: agentCLI)
    }

    /// The configured default launch options for an agent CLI family, validated
    /// against the family's available permission modes.
    public func configuredLaunchOptions(for agentCLI: AgentCLIKind) -> AgentLaunchOptions {
        configuration.defaultLaunchOptions(for: agentCLI)
            .validated(for: agentCLI, permissionModes: permissionModes(for: agentCLI))
    }

    /// The configured key binding for a keyboard-shortcut action.
    public func keyboardShortcutDefinition(for action: KeyboardShortcutAction)
        -> KeyboardShortcutDefinition
    {
        configuration.shortcut(for: action)
    }

    /// A shortcut is enabled only when it is bound *and* not part of a duplicate
    /// binding (two actions mapped to the same chord disable each other). Re-homed
    /// from the pre-rewrite `AppModel.isKeyboardShortcutEnabled`.
    public func isKeyboardShortcutEnabled(for action: KeyboardShortcutAction) -> Bool {
        let definition = keyboardShortcutDefinition(for: action)
        return definition.isBound
            && !configuration.keyboardShortcuts.duplicateActions().contains(action)
    }

    // MARK: - Lifecycle

    /// Hot-reloads configuration: validates, records a diagnostic, and notifies
    /// observers. Theme/font changes apply to live surfaces without restart (the
    /// render host observes `resolvedTheme`); descriptor invalidation lives in
    /// WorkspaceStore, which observes a reload via ``onReload``.
    public func reloadConfiguration(_ configuration: YAAWConfiguration) {
        self.configuration = configuration.validated(
            diagnosticRecorder: environment.diagnosticRecorder)
        recordDiagnostic(
            category: "Configuration",
            name: "settings_yaml_reloaded",
            metadata: [
                "theme": self.configuration.themeName,
                "default_agent": self.configuration.defaultAgentCLI.rawValue,
                "file_icon_pack": self.configuration.fileIconPack.rawValue,
                "interface_font_size": "\(self.configuration.fonts.interfaceSize)",
                "editor_font_size": "\(self.configuration.fonts.editorSize)",
                "terminal_font_size": "\(self.configuration.fonts.terminalSize)",
            ]
        )
        for handler in reloadHandlers { handler(self.configuration) }
    }

    /// Updates the live macOS appearance, no-op when unchanged.
    public func updateSystemAppearance(isDark: Bool) {
        guard systemAppearanceIsDark != isDark else { return }
        systemAppearanceIsDark = isDark
    }

    /// Re-probes each CLI's options, updates and persists the catalog, records a
    /// diagnostic, and returns the refreshed catalog.
    @discardableResult
    public func refreshAgentCLIOptionCatalog() -> AgentCLIOptionCatalog {
        let catalog = environment.agentCLIOptionCatalogService.refreshCatalog(
            configuration: configuration,
            resolver: environment.externalToolResolver,
            environment: environment.environment
        )
        agentCLIOptionCatalog = catalog
        recordDiagnostic(
            category: "AgentCLIOptions",
            name: "catalog_refreshed",
            metadata: ["agent_count": "\(catalog.entries.count)"]
        )
        return catalog
    }

    // MARK: - Reload observers

    @ObservationIgnored private var reloadHandlers: [@MainActor (YAAWConfiguration) -> Void] = []

    /// Registers a handler invoked on every `reloadConfiguration`. WorkspaceStore
    /// and ActivityStore use this to invalidate cached launch descriptors and
    /// refresh the file browser, preserving the pre-rewrite reload behavior.
    func onReload(_ handler: @escaping @MainActor (YAAWConfiguration) -> Void) {
        reloadHandlers.append(handler)
    }

    func recordDiagnostic(category: String, name: String, metadata: [String: String] = [:]) {
        environment.diagnosticRecorder.record(
            DiagnosticEvent(category: category, name: name, metadata: metadata))
    }
}
