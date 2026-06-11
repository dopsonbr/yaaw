import Foundation
import Yams

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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("settings.yaml")
    }

    public func ensureFileExists() throws {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try save(YAAWConfiguration())
    }

    public func loadText() throws -> String {
        try ensureFileExists()
        return try String(contentsOf: path, encoding: .utf8)
    }

    public func validate(text: String) throws -> YAAWConfiguration {
        try YAMLDecoder().decode(YAAWConfiguration.self, from: text)
            .validated(diagnosticRecorder: diagnosticRecorder)
    }

    public func load() -> YAAWConfiguration {
        do {
            return try validate(text: loadText())
        } catch {
            diagnosticRecorder.record(
                DiagnosticEvent(
                    category: "Configuration",
                    name: "settings_yaml_recovered",
                    metadata: [
                        "path": path.path,
                        "error": String(describing: error),
                    ]
                )
            )
            return YAAWConfiguration()
        }
    }

    public func save(_ configuration: YAAWConfiguration) throws {
        try saveText(Self.render(configuration.validated()))
    }

    public func saveText(_ text: String) throws {
        _ = try validate(text: text)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = text.data(using: .utf8) ?? Data()
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
            # schemaVersion is managed by YAAW; it drives on-load migrations. Do not edit.
            schemaVersion: \(configuration.schemaVersion)

            agent:
              # default: codex
              # active now: used when a flow needs a default CLI choice.
              default: \(configuration.agent.default.rawValue)
              launchDefaults:
            \(renderAgentLaunchDefaults(configuration.agent.launchDefaults))

            projects:
              # default: ~/yaaw
              # active now: global chats use this working directory.
              globalChatsDirectory: \(yamlScalar(configuration.projects.globalChatsDirectory))

            theme:
              # default: system
              # active now: controls app chrome, file browser colors, settings, panels, and terminals.
              # system follows the macOS appearance using the light/dark pairing below.
              # supported: system, \(ThemeCatalog.supportedIDs.joined(separator: ", "))
              active: \(configuration.theme.active)
              # active now: themes used by system mode in the light / dark appearance.
              light: \(configuration.theme.light)
              dark: \(configuration.theme.dark)
              # not changeable yet: custom palettes are reserved for future expansion.
              custom: {}

            icons:
              # default: material-file-icons
              # active now: controls file and folder icons only. App controls use native SF Symbols.
              # supported: material-file-icons, catppuccin-file-icons
              fileBrowserPack: \(yamlScalar(configuration.icons.fileBrowserPack))

            fonts:
              # default: system
              # active now: controls SwiftUI chrome, settings, sidebar, and (unless overridden below) file browser text.
              # use system for the native macOS UI font, or a real installed font family name.
              interfaceFamily: \(yamlScalar(configuration.fonts.interfaceFamily))
              # default: 13
              interfaceSize: \(configuration.fonts.interfaceSize.formattedFontSize)
              # default: JetBrains Mono
              # active now: controls in-app YAML/editor-style text.
              # use system-monospace for the native macOS monospaced font, or a real installed font family name.
              editorFamily: \(yamlScalar(configuration.fonts.editorFamily))
              # default: 13
              editorSize: \(configuration.fonts.editorSize.formattedFontSize)
              # default: JetBrains Mono (Ghostty's embedded terminal font). Use empty to leave Ghostty's configured font unchanged.
              # active now: set to an installed terminal font family such as "JetBrains Mono".
              terminalFamily: \(yamlScalar(configuration.fonts.terminalFamily))
              # default: 15
              terminalSize: \(configuration.fonts.terminalSize.formattedFontSize)
              # default: inherit, which follows interfaceFamily.
              # active now: controls the right-panel file browser list font only.
              # use inherit, system, system-monospace, or a real installed font family name.
              fileBrowserFamily: \(yamlScalar(configuration.fonts.fileBrowserFamily))
              # default: 0, which inherits interfaceSize. Set a value (9-28) to override.
              fileBrowserSize: \(configuration.fonts.fileBrowserSize.formattedFontSize)
              # default: true
              # active now: shapes editor and terminal ligatures when the font provides them.
              ligatures: \(configuration.fonts.ligatures)

            keyboardShortcuts:
            \(renderShortcuts(configuration.keyboardShortcuts))

            tools:
              editors:
                # default: [nvim, vim, vi]
                # active now: first available executable is used.
                preferred: \(inlineList(configuration.tools.editors.preferred))
              externalOpen:
                # default: zed
                # active now: project and file external-open default when available.
                default: \(yamlScalar(configuration.tools.externalOpen.default))
                # active now: detected destinations are shown in this order.
                # supported: \(inlineList(ExternalOpenToolID.allCases.map(\.rawValue)))
                preferred: \(inlineList(configuration.tools.externalOpen.preferred))
              git:
                # default: lazygit
                # active now.
                preferred: \(yamlScalar(configuration.tools.git.preferred))
              diff:
                # default setting: git diff; launched as git --no-pager diff.
                # active now when lazygit is unavailable.
                fallback: \(inlineList(configuration.tools.diff.fallback))
              agents:
                # active now: command names used for PATH lookup.
                codex: \(yamlScalar(configuration.tools.agents.codex))
                claude: \(yamlScalar(configuration.tools.agents.claude))
                opencode: \(yamlScalar(configuration.tools.agents.opencode))
                copilot: \(yamlScalar(configuration.tools.agents.copilot))

            fileBrowser:
              # default: browserPreview
              # active now: primary row open for Markdown and HTML files.
              # supported: browserPreview, editor
              markdownAndHTMLDefault: \(configuration.fileBrowser.markdownAndHTMLDefault.rawValue)

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

    private static func renderShortcuts(_ settings: KeyboardShortcutSettings) -> String {
        KeyboardShortcutAction.allCases.map { action in
            renderShortcut(
                action.rawValue,
                settings.definition(for: action),
                defaultText: action.defaultShortcutDescription,
                activeComment: "\(action.scope.rawValue): \(action.displayName)"
            )
        }
        .joined(separator: "\n")
    }

    private static func renderAgentLaunchDefaults(_ settings: AgentLaunchDefaultsSettings) -> String
    {
        AgentCLIKind.allCases.map { kind in
            let defaults = settings.defaults(for: kind)
            let mode = defaults.permissionModeID ?? AgentLaunchOptions.defaultPermissionModeID
            return """
                    \(kind.rawValue):
                      # default: permissionModeID default, additionalArguments []
                      permissionModeID: \(yamlScalar(mode))
                      additionalArguments: \(inlineList(defaults.additionalArguments))
                """
        }
        .joined(separator: "\n")
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
            !["true", "false", "null"].contains(value.lowercased())
        {
            return value
        }
        return
            "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
