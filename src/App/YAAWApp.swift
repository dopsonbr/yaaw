import YAAWKit
import AppKit
import SwiftUI

@main
struct YAAWApp: App {
    @StateObject private var model: AppModel
    private let startupError: Error?
    private let databasePath: URL
    private let configurationPath: URL
    private let configurationStore: YAMLConfigurationStore

    init() {
        var environment = ProcessInfo.processInfo.environment
        if let pathOverride = environment["YAAW_PATH"] {
            environment["PATH"] = pathOverride
        }
        let diagnostics = LoggerDiagnosticEventRecorder.shared
        let databasePath = Self.databasePath(environment: environment)
        let configurationPath = Self.configurationPath(environment: environment)
        self.databasePath = databasePath
        self.configurationPath = configurationPath
        self.configurationStore = YAMLConfigurationStore(path: configurationPath, diagnosticRecorder: diagnostics)
        do {
            diagnostics.record(DiagnosticEvent(category: "Lifecycle", name: "app_starting"))
            let store = try SQLiteYAAWStore(databasePath: databasePath, diagnosticRecorder: diagnostics)
            let configuration = configurationStore.load()
            let agentCLIBindings = AgentCLISessionBindingService(
                environment: environment,
                captureDirectory: Self.captureDirectory(environment: environment)
            )
            _model = StateObject(
                wrappedValue: AppModel(
                    store: store,
                    agentCLIBindings: agentCLIBindings,
                    configuration: configuration,
                    diagnosticRecorder: diagnostics,
                    environment: environment
                )
            )
            diagnostics.record(DiagnosticEvent(category: "Lifecycle", name: "app_ready"))
            startupError = nil
        } catch {
            diagnostics.record(
                DiagnosticEvent(
                    category: "Lifecycle",
                    name: "app_startup_failed",
                    metadata: ["error": String(describing: error)]
                )
            )
            _model = StateObject(wrappedValue: AppModel(store: InMemoryYAAWStore.helloWorld()))
            startupError = error
        }
    }

    var body: some Scene {
        WindowGroup("YAAW") {
            Group {
                if let startupError {
                    PersistenceStartupFailureView(
                        error: startupError,
                        databasePath: databasePath
                    )
                } else {
                    RootView(
                        model: model,
                        settingsPath: configurationPath,
                        onOpenSettingsFile: openSettingsFile,
                        onReloadSettings: reloadSettings
                    )
                }
            }
            .frame(minWidth: 1680, minHeight: 700)
            .toolbar(removing: .title)
        }
        .defaultSize(width: 1700, height: 900)
        .restorationBehavior(.disabled)
        .commands {
            if startupError == nil {
                CommandMenu("Terminal") {
                    Button("Toggle Bottom Terminal") {
                        model.toggleBottomTerminal()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .toggleBottomTerminal), modifiers: model.eventModifiers(for: .toggleBottomTerminal))
                }

                CommandMenu("Navigation") {
                    Button("Back") {
                        model.navigateBack()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .navigateBack), modifiers: model.eventModifiers(for: .navigateBack))

                    Button("Forward") {
                        model.navigateForward()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .navigateForward), modifiers: model.eventModifiers(for: .navigateForward))

                    Button("Previous Right Panel Mode") {
                        model.cycleRightPanelModeBackward()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .previousRightPanelMode), modifiers: model.eventModifiers(for: .previousRightPanelMode))

                    Button("Next Right Panel Mode") {
                        model.cycleRightPanelModeForward()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .nextRightPanelMode), modifiers: model.eventModifiers(for: .nextRightPanelMode))
                }

                CommandMenu("Layout") {
                    Button("Toggle Sidebar") {
                        model.toggleSidebarCollapsed()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .toggleSidebar), modifiers: model.eventModifiers(for: .toggleSidebar))

                    Button("Toggle Right Panel") {
                        model.toggleRightPanelCollapsed()
                    }
                    .keyboardShortcut(model.keyEquivalent(for: .toggleRightPanel), modifiers: model.eventModifiers(for: .toggleRightPanel))
                }
            }
        }
    }

    private static func databasePath(environment: [String: String]) -> URL {
        environment["YAAW_DATABASE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? SQLiteYAAWStore.defaultDatabasePath()
    }

    private static func configurationPath(environment: [String: String]) -> URL {
        environment["YAAW_CONFIG_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? YAMLConfigurationStore.defaultPath()
    }

    private static func captureDirectory(environment: [String: String]) -> URL? {
        environment["YAAW_CAPTURE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentCLISessionBindingService.defaultCaptureDirectory()
    }

    private func openSettingsFile() {
        if !FileManager.default.fileExists(atPath: configurationPath.path) {
            try? configurationStore.save(model.configuration)
        }
        NSWorkspace.shared.open(configurationPath)
    }

    private func reloadSettings() {
        model.reloadConfiguration(configurationStore.load())
    }
}

private extension AppModel {
    func keyEquivalent(for action: KeyboardShortcutAction) -> KeyEquivalent {
        let definition = keyboardShortcutDefinition(for: action)
        guard let character = definition.key.first else {
            return KeyEquivalent(" ")
        }
        return KeyEquivalent(character)
    }

    func eventModifiers(for action: KeyboardShortcutAction) -> EventModifiers {
        var eventModifiers = EventModifiers()
        for modifier in keyboardShortcutDefinition(for: action).modifiers {
            switch modifier {
            case .command:
                eventModifiers.insert(.command)
            case .shift:
                eventModifiers.insert(.shift)
            case .option:
                eventModifiers.insert(.option)
            case .control:
                eventModifiers.insert(.control)
            }
        }
        return eventModifiers
    }
}

private struct PersistenceStartupFailureView: View {
    let error: Error
    let databasePath: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("YAAW")
                .font(.title.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            Text("Persistence needs attention")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.red))

            Text("The app did not open an in-memory fallback because doing so could hide existing projects or threads.")
                .foregroundStyle(dracula(.foreground))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Database")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))

                Text(databasePath.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(dracula(.cyan))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Error")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))

                Text(String(describing: error))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(dracula(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }
}
