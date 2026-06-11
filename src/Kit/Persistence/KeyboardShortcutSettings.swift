import Foundation

public enum KeyboardShortcutScope: String, CaseIterable, Codable, Equatable, Sendable {
    case app = "App"
    case project = "Project"
    case thread = "Thread"
    case navigation = "Navigation"
    case rightPanel = "Right Panel"
    case files = "Files"
    case externalOpen = "External Open"
    case layout = "Layout"
    case terminal = "Terminal"
    case settings = "Settings"
}

public enum KeyboardShortcutAction: String, CaseIterable, Hashable, Identifiable, Sendable {
    case openSettings
    case newProject
    case newThread
    case toggleSelectedProjectPinned
    case moveSelectedProjectUp
    case moveSelectedProjectDown
    case toggleSelectedProjectExpanded
    case toggleSelectedProjectArchiveExpanded
    case toggleSelectedThreadPinned
    case archiveSelectedThread
    case unarchiveSelectedThread
    case toggleBottomTerminal
    case navigateBack
    case navigateForward
    case previousRightPanelMode
    case nextRightPanelMode
    case selectFilesRightPanelMode
    case selectGitRightPanelMode
    case selectNvimRightPanelMode
    case toggleSidebar
    case toggleRightPanel
    case swapMainAndRightPanels
    case refreshFiles
    case openNvimFilePicker
    case openSelectedFileInNvim
    case openSelectedDirectoryExternalDefault
    case openSelectedDirectoryInVSCode
    case openSelectedDirectoryInVSCodeInsiders
    case openSelectedDirectoryInSublimeText
    case openSelectedDirectoryInZed
    case openSelectedDirectoryInFinder
    case openSelectedDirectoryInTerminal
    case openSelectedDirectoryInGhostty
    case openSelectedDirectoryInXcode
    case openSelectedDirectoryInWebStorm
    case openSelectedFileExternalDefault
    case openSelectedFileInVSCode
    case openSelectedFileInVSCodeInsiders
    case openSelectedFileInSublimeText
    case openSelectedFileInZed
    case openSelectedFileInFinder
    case openSelectedFileInTerminal
    case openSelectedFileInGhostty
    case openSelectedFileInXcode
    case openSelectedFileInWebStorm
    case saveSettings
    case reloadSettings
    case revertSettings
    case openSettingsExternal

    public var id: String {
        rawValue
    }

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

    public var menuTitle: String {
        scope.rawValue
    }

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

    public var defaultShortcutDescription: String {
        defaultShortcut.displayText
    }
}

public enum KeyboardShortcutModifier: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case command
    case shift
    case option
    case control
}

public struct KeyboardShortcutDefinition: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [KeyboardShortcutModifier]

    public static let unbound = KeyboardShortcutDefinition(key: "", modifiers: [])

    public init(key: String, modifiers: [KeyboardShortcutModifier]) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.modifiers =
            try container.decodeIfPresent(
                [KeyboardShortcutModifier].self,
                forKey: .modifiers
            ) ?? []
    }

    public var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isUnbound: Bool {
        normalizedKey.isEmpty && modifiers.isEmpty
    }

    public var isBound: Bool {
        !isUnbound
    }

    public var isValid: Bool {
        isUnbound || (normalizedKey.count == 1 && !modifiers.isEmpty)
    }

    public var signature: String? {
        guard isBound, isValid else { return nil }
        let modifierText = modifiers.map(\.rawValue).sorted().joined(separator: "+")
        return "\(modifierText)+\(normalizedKey)"
    }

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

public struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    public var definitions: [KeyboardShortcutAction: KeyboardShortcutDefinition]

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

    public init(definitions: [KeyboardShortcutAction: KeyboardShortcutDefinition]) {
        self.definitions = Self.defaultDefinitions.merging(definitions) { _, override in override }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded = Self.defaultDefinitions
        for key in container.allKeys {
            guard let action = KeyboardShortcutAction(rawValue: key.stringValue) else { continue }
            decoded[action] = try container.decode(KeyboardShortcutDefinition.self, forKey: key)
        }
        self.definitions = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for action in KeyboardShortcutAction.allCases {
            try container.encode(definition(for: action), forKey: DynamicCodingKey(action.rawValue))
        }
    }

    public func definition(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition {
        definitions[action] ?? action.defaultShortcut
    }

    public mutating func setDefinition(
        _ definition: KeyboardShortcutDefinition, for action: KeyboardShortcutAction
    ) {
        definitions[action] = definition
    }

    public func duplicateActions() -> Set<KeyboardShortcutAction> {
        var actionsBySignature: [String: [KeyboardShortcutAction]] = [:]
        for action in KeyboardShortcutAction.allCases {
            guard let signature = definition(for: action).signature else { continue }
            actionsBySignature[signature, default: []].append(action)
        }
        return Set(actionsBySignature.values.filter { $0.count > 1 }.flatMap { $0 })
    }

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

    public static let defaultToggleBottomTerminal = KeyboardShortcutDefinition(
        key: "j", modifiers: [.command])
    public static let defaultNavigateBack = KeyboardShortcutDefinition(
        key: "[", modifiers: [.command])
    public static let defaultNavigateForward = KeyboardShortcutDefinition(
        key: "]", modifiers: [.command])
    public static let defaultPreviousRightPanelMode = KeyboardShortcutDefinition(
        key: "[", modifiers: [.command, .shift])
    public static let defaultNextRightPanelMode = KeyboardShortcutDefinition(
        key: "]", modifiers: [.command, .shift])
    public static let defaultToggleSidebar = KeyboardShortcutDefinition(
        key: "s", modifiers: [.command, .option])
    public static let defaultToggleRightPanel = KeyboardShortcutDefinition(
        key: "r", modifiers: [.command, .option])

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
