import Foundation

/// The functional grouping a keyboard shortcut action belongs to, used to organize
/// shortcuts in menus and settings.
public enum KeyboardShortcutScope: String, CaseIterable, Codable, Equatable, Sendable {
    /// App-wide actions such as opening Settings.
    case app = "App"
    /// Actions that operate on projects.
    case project = "Project"
    /// Actions that operate on threads.
    case thread = "Thread"
    /// History navigation actions (back and forward).
    case navigation = "Navigation"
    /// Actions that control the right panel modes.
    case rightPanel = "Right Panel"
    /// File browser actions.
    case files = "Files"
    /// Actions that open selected files or directories in external tools.
    case externalOpen = "External Open"
    /// Window layout actions such as toggling the sidebar or right panel.
    case layout = "Layout"
    /// Bottom terminal actions.
    case terminal = "Terminal"
    /// Settings management actions such as saving or reloading settings.
    case settings = "Settings"
}

/// A user-rebindable action that can be triggered by a keyboard shortcut.
public enum KeyboardShortcutAction: String, CaseIterable, Hashable, Identifiable, Sendable {
    /// Open the Settings window.
    case openSettings
    /// Create a new project.
    case newProject
    /// Create a new thread.
    case newThread
    /// Pin or unpin the selected project.
    case toggleSelectedProjectPinned
    /// Move the selected project up in the sidebar.
    case moveSelectedProjectUp
    /// Move the selected project down in the sidebar.
    case moveSelectedProjectDown
    /// Expand or collapse the selected project.
    case toggleSelectedProjectExpanded
    /// Expand or collapse the selected project's archive section.
    case toggleSelectedProjectArchiveExpanded
    /// Pin or unpin the selected thread.
    case toggleSelectedThreadPinned
    /// Archive the selected thread.
    case archiveSelectedThread
    /// Unarchive the selected thread.
    case unarchiveSelectedThread
    /// Show or hide the bottom terminal.
    case toggleBottomTerminal
    /// Navigate back in history.
    case navigateBack
    /// Navigate forward in history.
    case navigateForward
    /// Switch to the previous right panel mode.
    case previousRightPanelMode
    /// Switch to the next right panel mode.
    case nextRightPanelMode
    /// Switch the right panel to the Files mode.
    case selectFilesRightPanelMode
    /// Switch the right panel to the Git mode.
    case selectGitRightPanelMode
    /// Switch the right panel to the nvim mode.
    case selectNvimRightPanelMode
    /// Show or hide the sidebar.
    case toggleSidebar
    /// Show or hide the right-side area.
    case toggleRightPanel
    /// Swap the main and right panels.
    case swapMainAndRightPanels
    /// Refresh the file browser.
    case refreshFiles
    /// Open the nvim file picker.
    case openNvimFilePicker
    /// Open the selected file in nvim.
    case openSelectedFileInNvim
    /// Open the selected directory with the default external tool.
    case openSelectedDirectoryExternalDefault
    /// Open the selected directory in VS Code.
    case openSelectedDirectoryInVSCode
    /// Open the selected directory in VS Code Insiders.
    case openSelectedDirectoryInVSCodeInsiders
    /// Open the selected directory in Sublime Text.
    case openSelectedDirectoryInSublimeText
    /// Open the selected directory in Zed.
    case openSelectedDirectoryInZed
    /// Open the selected directory in Finder.
    case openSelectedDirectoryInFinder
    /// Open the selected directory in Terminal.
    case openSelectedDirectoryInTerminal
    /// Open the selected directory in Ghostty.
    case openSelectedDirectoryInGhostty
    /// Open the selected directory in Xcode.
    case openSelectedDirectoryInXcode
    /// Open the selected directory in WebStorm.
    case openSelectedDirectoryInWebStorm
    /// Open the selected file with the default external tool.
    case openSelectedFileExternalDefault
    /// Open the selected file in VS Code.
    case openSelectedFileInVSCode
    /// Open the selected file in VS Code Insiders.
    case openSelectedFileInVSCodeInsiders
    /// Open the selected file in Sublime Text.
    case openSelectedFileInSublimeText
    /// Open the selected file in Zed.
    case openSelectedFileInZed
    /// Open the selected file in Finder.
    case openSelectedFileInFinder
    /// Open the selected file in Terminal.
    case openSelectedFileInTerminal
    /// Open the selected file in Ghostty.
    case openSelectedFileInGhostty
    /// Open the selected file in Xcode.
    case openSelectedFileInXcode
    /// Open the selected file in WebStorm.
    case openSelectedFileInWebStorm
    /// Save the current settings.
    case saveSettings
    /// Reload settings from disk.
    case reloadSettings
    /// Revert unsaved settings changes.
    case revertSettings
    /// Open the settings YAML file in an external editor.
    case openSettingsExternal

    /// The stable identifier for the action, matching its raw value.
    public var id: String {
        rawValue
    }

    /// The human-readable name shown in the UI for this action.
    public var displayName: String {
        switch self {
        case .openSettings:
            "Open Settings"
        case .newProject:
            "New Project"
        case .newThread:
            "New Thread"
        case .toggleSelectedProjectPinned:
            "Pin or Unpin Selected Project"
        case .moveSelectedProjectUp:
            "Move Selected Project Up"
        case .moveSelectedProjectDown:
            "Move Selected Project Down"
        case .toggleSelectedProjectExpanded:
            "Expand or Collapse Selected Project"
        case .toggleSelectedProjectArchiveExpanded:
            "Expand or Collapse Selected Project Archive"
        case .toggleSelectedThreadPinned:
            "Pin or Unpin Selected Thread"
        case .archiveSelectedThread:
            "Archive Selected Thread"
        case .unarchiveSelectedThread:
            "Unarchive Selected Thread"
        case .toggleBottomTerminal:
            "Toggle Bottom Terminal"
        case .navigateBack:
            "Back"
        case .navigateForward:
            "Forward"
        case .previousRightPanelMode:
            "Previous Right Panel Mode"
        case .nextRightPanelMode:
            "Next Right Panel Mode"
        case .selectFilesRightPanelMode:
            "Select Files"
        case .selectGitRightPanelMode:
            "Select Git"
        case .selectNvimRightPanelMode:
            "Select nvim"
        case .toggleSidebar:
            "Toggle Sidebar"
        case .toggleRightPanel:
            "Toggle Right-Side Area"
        case .swapMainAndRightPanels:
            "Swap Main and Right Panels"
        case .refreshFiles:
            "Refresh Files"
        case .openNvimFilePicker:
            "Open nvim File Picker"
        case .openSelectedFileInNvim:
            "Open Selected File in nvim"
        case .openSelectedDirectoryExternalDefault:
            "Open Selected Directory with Default Tool"
        case .openSelectedDirectoryInVSCode:
            "Open Selected Directory in VS Code"
        case .openSelectedDirectoryInVSCodeInsiders:
            "Open Selected Directory in VS Code Insiders"
        case .openSelectedDirectoryInSublimeText:
            "Open Selected Directory in Sublime Text"
        case .openSelectedDirectoryInZed:
            "Open Selected Directory in Zed"
        case .openSelectedDirectoryInFinder:
            "Open Selected Directory in Finder"
        case .openSelectedDirectoryInTerminal:
            "Open Selected Directory in Terminal"
        case .openSelectedDirectoryInGhostty:
            "Open Selected Directory in Ghostty"
        case .openSelectedDirectoryInXcode:
            "Open Selected Directory in Xcode"
        case .openSelectedDirectoryInWebStorm:
            "Open Selected Directory in WebStorm"
        case .openSelectedFileExternalDefault:
            "Open Selected File with Default Tool"
        case .openSelectedFileInVSCode:
            "Open Selected File in VS Code"
        case .openSelectedFileInVSCodeInsiders:
            "Open Selected File in VS Code Insiders"
        case .openSelectedFileInSublimeText:
            "Open Selected File in Sublime Text"
        case .openSelectedFileInZed:
            "Open Selected File in Zed"
        case .openSelectedFileInFinder:
            "Open Selected File in Finder"
        case .openSelectedFileInTerminal:
            "Open Selected File in Terminal"
        case .openSelectedFileInGhostty:
            "Open Selected File in Ghostty"
        case .openSelectedFileInXcode:
            "Open Selected File in Xcode"
        case .openSelectedFileInWebStorm:
            "Open Selected File in WebStorm"
        case .saveSettings:
            "Save Settings"
        case .reloadSettings:
            "Reload Settings"
        case .revertSettings:
            "Revert Settings"
        case .openSettingsExternal:
            "Open Settings YAML Externally"
        }
    }

    /// The scope this action is grouped under in menus and settings.
    public var scope: KeyboardShortcutScope {
        switch self {
        case .openSettings:
            .app
        case .newProject, .toggleSelectedProjectPinned, .moveSelectedProjectUp,
            .moveSelectedProjectDown,
            .toggleSelectedProjectExpanded, .toggleSelectedProjectArchiveExpanded:
            .project
        case .newThread, .toggleSelectedThreadPinned, .archiveSelectedThread,
            .unarchiveSelectedThread:
            .thread
        case .navigateBack, .navigateForward:
            .navigation
        case .previousRightPanelMode, .nextRightPanelMode, .selectFilesRightPanelMode,
            .selectGitRightPanelMode,
            .selectNvimRightPanelMode, .openNvimFilePicker:
            .rightPanel
        case .toggleSidebar, .toggleRightPanel, .swapMainAndRightPanels:
            .layout
        case .toggleBottomTerminal:
            .terminal
        case .refreshFiles, .openSelectedFileInNvim:
            .files
        case .openSelectedDirectoryExternalDefault, .openSelectedDirectoryInVSCode,
            .openSelectedDirectoryInVSCodeInsiders, .openSelectedDirectoryInSublimeText,
            .openSelectedDirectoryInZed, .openSelectedDirectoryInFinder,
            .openSelectedDirectoryInTerminal,
            .openSelectedDirectoryInGhostty, .openSelectedDirectoryInXcode,
            .openSelectedDirectoryInWebStorm,
            .openSelectedFileExternalDefault, .openSelectedFileInVSCode,
            .openSelectedFileInVSCodeInsiders,
            .openSelectedFileInSublimeText, .openSelectedFileInZed, .openSelectedFileInFinder,
            .openSelectedFileInTerminal, .openSelectedFileInGhostty, .openSelectedFileInXcode,
            .openSelectedFileInWebStorm:
            .externalOpen
        case .saveSettings, .reloadSettings, .revertSettings, .openSettingsExternal:
            .settings
        }
    }

    /// The menu section title for this action, derived from its scope.
    public var menuTitle: String {
        scope.rawValue
    }

    /// The default key binding for this action, or `.unbound` if it has none by default.
    public var defaultShortcut: KeyboardShortcutDefinition {
        switch self {
        case .openSettings:
            KeyboardShortcutDefinition(key: ",", modifiers: [.command])
        case .newProject:
            KeyboardShortcutDefinition(key: "n", modifiers: [.command])
        case .newThread:
            KeyboardShortcutDefinition(key: "n", modifiers: [.command, .shift])
        case .toggleBottomTerminal:
            KeyboardShortcutDefinition(key: "j", modifiers: [.command])
        case .navigateBack:
            KeyboardShortcutDefinition(key: "[", modifiers: [.command])
        case .navigateForward:
            KeyboardShortcutDefinition(key: "]", modifiers: [.command])
        case .previousRightPanelMode:
            KeyboardShortcutDefinition(key: "[", modifiers: [.command, .shift])
        case .nextRightPanelMode:
            KeyboardShortcutDefinition(key: "]", modifiers: [.command, .shift])
        case .selectFilesRightPanelMode:
            KeyboardShortcutDefinition(key: "1", modifiers: [.command])
        case .selectGitRightPanelMode:
            KeyboardShortcutDefinition(key: "2", modifiers: [.command])
        case .selectNvimRightPanelMode:
            KeyboardShortcutDefinition(key: "3", modifiers: [.command])
        case .toggleSidebar:
            KeyboardShortcutDefinition(key: "s", modifiers: [.command, .option])
        case .toggleRightPanel:
            KeyboardShortcutDefinition(key: "r", modifiers: [.command, .option])
        case .refreshFiles:
            KeyboardShortcutDefinition(key: "r", modifiers: [.command])
        case .reloadSettings:
            KeyboardShortcutDefinition(key: "r", modifiers: [.command, .shift])
        case .saveSettings:
            KeyboardShortcutDefinition(key: "s", modifiers: [.command])
        default:
            .unbound
        }
    }

    /// A human-readable description of the default shortcut (for example, "Cmd+S").
    public var defaultShortcutDescription: String {
        defaultShortcut.displayText
    }
}

/// A modifier key that can be part of a keyboard shortcut.
public enum KeyboardShortcutModifier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// The Command (⌘) modifier.
    case command
    /// The Shift (⇧) modifier.
    case shift
    /// The Option (⌥) modifier.
    case option
    /// The Control (⌃) modifier.
    case control
}

/// A concrete keyboard shortcut: a base key plus its required modifier keys.
public struct KeyboardShortcutDefinition: Codable, Equatable, Sendable {
    /// The base (non-modifier) key, such as "s" or "[".
    public var key: String
    /// The modifier keys required alongside the base key.
    public var modifiers: [KeyboardShortcutModifier]

    /// A definition representing no binding (empty key and modifiers).
    public static let unbound = KeyboardShortcutDefinition(key: "", modifiers: [])

    /// Creates a shortcut definition from a base key and its modifiers.
    public init(key: String, modifiers: [KeyboardShortcutModifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Decodes a shortcut definition, defaulting missing fields to empty values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.modifiers =
            try container.decodeIfPresent(
                [KeyboardShortcutModifier].self,
                forKey: .modifiers
            ) ?? []
    }

    /// The base key trimmed of whitespace and lowercased for comparison.
    public var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether this definition represents no binding.
    public var isUnbound: Bool {
        normalizedKey.isEmpty && modifiers.isEmpty
    }

    /// Whether this definition has a binding.
    public var isBound: Bool {
        !isUnbound
    }

    /// Whether this definition is either unbound or a single key with at least one modifier.
    public var isValid: Bool {
        isUnbound || (normalizedKey.count == 1 && !modifiers.isEmpty)
    }

    /// A stable signature used to detect conflicting bindings, or `nil` if unbound or invalid.
    public var signature: String? {
        guard isBound, isValid else { return nil }
        let modifierText = modifiers.map(\.rawValue).sorted().joined(separator: "+")
        return "\(modifierText)+\(normalizedKey)"
    }

    /// A human-readable representation of the shortcut (for example, "Cmd+Shift+]"), or "Unbound".
    public var displayText: String {
        guard isBound else { return "Unbound" }
        let modifierText = modifiers.map { modifier in
            switch modifier {
            case .command:
                "Cmd"
            case .shift:
                "Shift"
            case .option:
                "Option"
            case .control:
                "Control"
            }
        }
        return (modifierText + [key.trimmingCharacters(in: .whitespacesAndNewlines)]).joined(
            separator: "+")
    }

    internal func validated(fallback: KeyboardShortcutDefinition) -> KeyboardShortcutDefinition {
        isValid ? self : fallback
    }
}

/// The user's complete set of keyboard shortcut bindings, keyed by action.
public struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    /// The shortcut binding for each action.
    public var definitions: [KeyboardShortcutAction: KeyboardShortcutDefinition]

    /// Creates settings from the defaults, overriding the handful of commonly customized bindings.
    public init(
        toggleBottomTerminal: KeyboardShortcutDefinition = Self.defaultToggleBottomTerminal,
        navigateBack: KeyboardShortcutDefinition = Self.defaultNavigateBack,
        navigateForward: KeyboardShortcutDefinition = Self.defaultNavigateForward,
        previousRightPanelMode: KeyboardShortcutDefinition = Self.defaultPreviousRightPanelMode,
        nextRightPanelMode: KeyboardShortcutDefinition = Self.defaultNextRightPanelMode,
        toggleSidebar: KeyboardShortcutDefinition = Self.defaultToggleSidebar,
        toggleRightPanel: KeyboardShortcutDefinition = Self.defaultToggleRightPanel
    ) {
        var definitions = Self.defaultDefinitions
        definitions[.toggleBottomTerminal] = toggleBottomTerminal
        definitions[.navigateBack] = navigateBack
        definitions[.navigateForward] = navigateForward
        definitions[.previousRightPanelMode] = previousRightPanelMode
        definitions[.nextRightPanelMode] = nextRightPanelMode
        definitions[.toggleSidebar] = toggleSidebar
        definitions[.toggleRightPanel] = toggleRightPanel
        self.definitions = definitions
    }

    /// Creates settings by merging the given bindings over the defaults.
    public init(definitions: [KeyboardShortcutAction: KeyboardShortcutDefinition]) {
        self.definitions = Self.defaultDefinitions.merging(definitions) { _, override in override }
    }

    /// Decodes settings, falling back to defaults for any actions not present in the payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded = Self.defaultDefinitions
        for key in container.allKeys {
            guard let action = KeyboardShortcutAction(rawValue: key.stringValue) else { continue }
            decoded[action] = try container.decode(KeyboardShortcutDefinition.self, forKey: key)
        }
        self.definitions = decoded
    }

    /// Encodes every action's resolved binding using the action raw value as the key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for action in KeyboardShortcutAction.allCases {
            try container.encode(definition(for: action), forKey: DynamicCodingKey(action.rawValue))
        }
    }

    /// Returns the binding for the given action, falling back to its default if unset.
    public func definition(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition {
        definitions[action] ?? action.defaultShortcut
    }

    /// Sets the binding for the given action.
    public mutating func setDefinition(
        _ definition: KeyboardShortcutDefinition, for action: KeyboardShortcutAction
    ) {
        definitions[action] = definition
    }

    /// Returns the set of actions whose bindings collide with another action's binding.
    public func duplicateActions() -> Set<KeyboardShortcutAction> {
        var actionsBySignature: [String: [KeyboardShortcutAction]] = [:]
        for action in KeyboardShortcutAction.allCases {
            guard let signature = definition(for: action).signature else { continue }
            actionsBySignature[signature, default: []].append(action)
        }
        return Set(actionsBySignature.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Whether any two actions share the same binding.
    public func hasDuplicateBindings() -> Bool {
        !duplicateActions().isEmpty
    }

    internal func validated() -> KeyboardShortcutSettings {
        var validated: [KeyboardShortcutAction: KeyboardShortcutDefinition] = [:]
        for action in KeyboardShortcutAction.allCases {
            validated[action] = definition(for: action).validated(fallback: action.defaultShortcut)
        }
        return KeyboardShortcutSettings(definitions: validated)
    }

    /// The default binding for toggling the bottom terminal (Cmd+J).
    public static let defaultToggleBottomTerminal = KeyboardShortcutDefinition(
        key: "j", modifiers: [.command])
    /// The default binding for navigating back (Cmd+[).
    public static let defaultNavigateBack = KeyboardShortcutDefinition(
        key: "[", modifiers: [.command])
    /// The default binding for navigating forward (Cmd+]).
    public static let defaultNavigateForward = KeyboardShortcutDefinition(
        key: "]", modifiers: [.command])
    /// The default binding for the previous right panel mode (Cmd+Shift+[).
    public static let defaultPreviousRightPanelMode = KeyboardShortcutDefinition(
        key: "[", modifiers: [.command, .shift])
    /// The default binding for the next right panel mode (Cmd+Shift+]).
    public static let defaultNextRightPanelMode = KeyboardShortcutDefinition(
        key: "]", modifiers: [.command, .shift])
    /// The default binding for toggling the sidebar (Cmd+Option+S).
    public static let defaultToggleSidebar = KeyboardShortcutDefinition(
        key: "s", modifiers: [.command, .option])
    /// The default binding for toggling the right panel (Cmd+Option+R).
    public static let defaultToggleRightPanel = KeyboardShortcutDefinition(
        key: "r", modifiers: [.command, .option])

    /// The full set of default bindings for every action.
    public static let defaultDefinitions: [KeyboardShortcutAction: KeyboardShortcutDefinition] = {
        Dictionary(
            uniqueKeysWithValues: KeyboardShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    }()
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
