import AppKit
import SwiftUI
import YAAWKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case agents
    case appearance
    case keyboardShortcuts = "keyboard-shortcuts"
    case configFile = "config-file"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .appearance: "Appearance"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        case .configFile: "Config File"
        }
    }

    var systemSymbolName: String {
        switch self {
        case .general: "gearshape"
        case .agents: "apple.terminal"
        case .appearance: "paintpalette"
        case .keyboardShortcuts: "keyboard"
        case .configFile: "doc.text"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general:
            ["default agent", "markdown", "html", "cli options", "global chats", "directory"]
        case .agents:
            [
                "command", "permissions", "arguments", "launch", "codex", "claude", "opencode",
                "copilot",
            ]
        case .appearance:
            ["theme", "font", "interface", "editor", "terminal", "file browser", "size", "color"]
        case .keyboardShortcuts:
            ["key bindings", "shortcut", "modifier", "hotkey"]
        case .configFile:
            ["yaml", "save", "reload", "revert", "open external", "file", "raw"]
        }
    }
}

/// Self-contained `@Observable` driving the Settings window. Holds the YAML
/// editor state machine + per-field bindings; mutations route through injected
/// `Dependencies` that validate/save the YAML and notify the live `SettingsStore`.
/// Ported from the pre-rewrite SettingsModel; the only wiring change is that the
/// `reloadConfiguration`/`refreshAgentCLIOptions` deps call into `SettingsStore`.
@MainActor
@Observable
final class SettingsModel {
    struct Dependencies {
        let settingsPath: URL
        let loadText: () throws -> String
        let validateText: (String) throws -> YAAWConfiguration
        let saveText: (String) throws -> YAAWConfiguration
        let openExternal: () -> Void
        let reloadConfiguration: () -> Void
        let refreshAgentCLIOptions: () -> AgentCLIOptionCatalog
    }

    let dependencies: Dependencies

    var selectedSection: SettingsSection = .general
    var sidebarSearchText = ""
    var shortcutSearchText = ""

    var editorText = ""
    var lastSavedText = ""
    var statusMessage = "Loading settings..."
    var validationError: String?
    var isShowingDiscardConfirmation = false
    var selectedThemeID = ThemeSettings.systemActiveID
    var currentConfiguration = YAAWConfiguration()
    var globalChatsDirectoryText = ProjectSettings.defaultGlobalChatsDirectory
    var agentCommandTextByKind: [AgentCLIKind: String] = [:]
    var agentArgumentsTextByKind: [AgentCLIKind: String] = [:]
    private var hasLoaded = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var settingsPath: URL { dependencies.settingsPath }

    var hasUnsavedChanges: Bool {
        editorText != lastSavedText
    }

    var effectiveFonts: FontSettings {
        currentConfiguration.validated().fonts
    }

    var filteredSections: [SettingsSection] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.title.lowercased().contains(query)
                || section.searchKeywords.contains { $0.contains(query) }
        }
    }

    var filteredShortcutActions: [KeyboardShortcutAction] {
        let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return KeyboardShortcutAction.allCases }
        return KeyboardShortcutAction.allCases.filter {
            $0.displayName.lowercased().contains(query)
                || $0.scope.rawValue.lowercased().contains(query)
                || $0.rawValue.lowercased().contains(query)
        }
    }

    // MARK: - Config file state machine

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reloadFromDisk()
    }

    func requestReload() {
        guard hasUnsavedChanges else {
            reloadFromDisk()
            return
        }
        isShowingDiscardConfirmation = true
    }

    func reloadFromDisk() {
        do {
            let text = try dependencies.loadText()
            editorText = text
            lastSavedText = text
            do {
                let configuration = try dependencies.validateText(text)
                currentConfiguration = configuration
                selectedThemeID = configuration.themeName
                globalChatsDirectoryText = configuration.projects.globalChatsDirectory
                syncAgentLaunchTextFields(with: configuration)
                validationError = nil
                dependencies.reloadConfiguration()
                statusMessage = "Settings reloaded from disk."
            } catch {
                validationError = "YAML validation failed: \(error)"
                statusMessage = "Settings file loaded with validation errors."
            }
        } catch {
            validationError = "Could not load settings: \(error)"
            statusMessage = "Settings file could not be loaded."
        }
    }

    func save() {
        do {
            _ = try dependencies.saveText(editorText)
            let configuration = try dependencies.validateText(editorText)
            currentConfiguration = configuration
            selectedThemeID = configuration.themeName
            globalChatsDirectoryText = configuration.projects.globalChatsDirectory
            syncAgentLaunchTextFields(with: configuration)
            lastSavedText = editorText
            validationError = nil
            statusMessage = "Settings saved and applied."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Settings were not saved."
        }
    }

    func revert() {
        editorText = lastSavedText
        do {
            let configuration = try dependencies.validateText(editorText)
            currentConfiguration = configuration
            selectedThemeID = configuration.themeName
            globalChatsDirectoryText = configuration.projects.globalChatsDirectory
            syncAgentLaunchTextFields(with: configuration)
            validationError = nil
            statusMessage = "Unsaved edits reverted."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Reverted to the last loaded file contents."
        }
    }

    func openExternal() {
        dependencies.openExternal()
    }

    func saveConfigurationMutation(
        successStatus: String,
        failureStatus: String,
        mutate: (inout YAAWConfiguration) -> Void
    ) {
        do {
            var nextConfiguration = try dependencies.validateText(editorText)
            mutate(&nextConfiguration)
            nextConfiguration = nextConfiguration.validated()
            let renderedText = YAMLConfigurationStore.render(nextConfiguration)
            _ = try dependencies.saveText(renderedText)
            editorText = renderedText
            lastSavedText = renderedText
            currentConfiguration = nextConfiguration
            selectedThemeID = nextConfiguration.themeName
            globalChatsDirectoryText = nextConfiguration.projects.globalChatsDirectory
            syncAgentLaunchTextFields(with: nextConfiguration)
            validationError = nil
            statusMessage = successStatus
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = failureStatus
        }
    }

    func syncAgentLaunchTextFields(with configuration: YAAWConfiguration) {
        agentCommandTextByKind = Dictionary(
            uniqueKeysWithValues: AgentCLIKind.allCases.map {
                ($0, configuration.agentExecutableName(for: $0))
            }
        )
        agentArgumentsTextByKind = Dictionary(
            uniqueKeysWithValues: AgentCLIKind.allCases.map { kind in
                (
                    kind,
                    AgentLaunchOptions.formatAdditionalArguments(
                        configuration.agent.launchDefaults.defaults(for: kind).additionalArguments)
                )
            }
        )
    }

    // MARK: - General

    var defaultAgentSelection: Binding<AgentCLIKind> {
        Binding(
            get: { self.currentConfiguration.agent.default },
            set: { newValue in
                self.saveConfigurationMutation(
                    successStatus: "Default agent saved and applied.",
                    failureStatus: "Default agent was not changed."
                ) {
                    $0.agent.default = newValue
                }
            }
        )
    }

    var markdownHTMLDefaultSelection: Binding<FileBrowserMarkdownAndHTMLDefault> {
        Binding(
            get: { self.currentConfiguration.fileBrowser.markdownAndHTMLDefault },
            set: { newValue in
                self.saveConfigurationMutation(
                    successStatus: "File browser setting saved and applied.",
                    failureStatus: "File browser setting was not changed."
                ) {
                    $0.fileBrowser.markdownAndHTMLDefault = newValue
                }
            }
        )
    }

    func refreshAgentCLIOptions() {
        let catalog = dependencies.refreshAgentCLIOptions()
        statusMessage = "CLI options refreshed for \(catalog.entries.count) agent commands."
        validationError = nil
    }

    func chooseGlobalChatsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = currentConfiguration.projects.resolvedGlobalChatsDirectory()
        if panel.runModal() == .OK, let url = panel.url {
            globalChatsDirectoryText = url.standardizedFileURL.path
            saveProjectSettings()
        }
    }

    func saveProjectSettings() {
        saveConfigurationMutation(
            successStatus: "Project settings saved and applied.",
            failureStatus: "Project settings were not changed."
        ) {
            $0.projects.globalChatsDirectory =
                globalChatsDirectoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Agents

    func agentCommandBinding(for kind: AgentCLIKind) -> Binding<String> {
        Binding(
            get: {
                self.agentCommandTextByKind[kind]
                    ?? self.currentConfiguration.agentExecutableName(for: kind)
            },
            set: { self.agentCommandTextByKind[kind] = $0 }
        )
    }

    func agentArgumentsBinding(for kind: AgentCLIKind) -> Binding<String> {
        Binding(
            get: {
                self.agentArgumentsTextByKind[kind]
                    ?? AgentLaunchOptions.formatAdditionalArguments(
                        self.currentConfiguration.agent.launchDefaults.defaults(for: kind)
                            .additionalArguments
                    )
            },
            set: { self.agentArgumentsTextByKind[kind] = $0 }
        )
    }

    func agentPermissionSelection(for kind: AgentCLIKind) -> Binding<String> {
        Binding(
            get: {
                self.currentConfiguration.agent.launchDefaults.defaults(for: kind)
                    .permissionModeID
                    ?? AgentLaunchOptions.defaultPermissionModeID
            },
            set: { newValue in
                self.saveConfigurationMutation(
                    successStatus: "\(kind.displayName) permission default saved and applied.",
                    failureStatus: "\(kind.displayName) permission default was not changed."
                ) {
                    var defaults = $0.agent.launchDefaults.defaults(for: kind)
                    defaults.permissionModeID =
                        newValue == AgentLaunchOptions.defaultPermissionModeID ? nil : newValue
                    $0.agent.launchDefaults.setDefaults(defaults, for: kind)
                }
            }
        )
    }

    func saveAgentLaunchSettings(for kind: AgentCLIKind) {
        do {
            let additionalArguments = try AgentLaunchOptions.parseAdditionalArguments(
                agentArgumentsTextByKind[kind] ?? "")
            saveConfigurationMutation(
                successStatus: "\(kind.displayName) launch defaults saved and applied.",
                failureStatus: "\(kind.displayName) launch defaults were not changed."
            ) {
                $0.tools.agents.setExecutableName(
                    (agentCommandTextByKind[kind] ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    for: kind
                )
                var defaults = $0.agent.launchDefaults.defaults(for: kind)
                defaults.additionalArguments = additionalArguments
                $0.agent.launchDefaults.setDefaults(defaults, for: kind)
            }
        } catch is AgentLaunchOptionsArgumentError {
            validationError = "\(kind.displayName) arguments are not valid."
            statusMessage = "\(kind.displayName) launch defaults were not changed."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "\(kind.displayName) launch defaults were not changed."
        }
    }

}
