import YAAWKit
import SwiftUI

@main
struct YAAWApp: App {
    @StateObject private var model: AppModel
    private let startupError: Error?
    private let databasePath: URL

    init() {
        var environment = ProcessInfo.processInfo.environment
        if let pathOverride = environment["YAAW_PATH"] {
            environment["PATH"] = pathOverride
        }
        let diagnostics = LoggerDiagnosticEventRecorder.shared
        let databasePath = Self.databasePath(environment: environment)
        self.databasePath = databasePath
        do {
            diagnostics.record(DiagnosticEvent(category: "Lifecycle", name: "app_starting"))
            let store = try SQLiteYAAWStore(databasePath: databasePath, diagnosticRecorder: diagnostics)
            let configuration = JSONConfigurationStore(path: Self.configurationPath(environment: environment)).load()
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
                    RootView(model: model)
                }
            }
            .frame(minWidth: 1680, minHeight: 700)
        }
        .defaultSize(width: 1700, height: 900)
        .commands {
            if startupError == nil {
                CommandMenu("Terminal") {
                    Button("Toggle Bottom Terminal") {
                        model.toggleBottomTerminal()
                    }
                    .keyboardShortcut("j", modifiers: [.command])
                }

                CommandMenu("Navigation") {
                    Button("Back") {
                        model.navigateBack()
                    }
                    .keyboardShortcut("[", modifiers: [.command])

                    Button("Forward") {
                        model.navigateForward()
                    }
                    .keyboardShortcut("]", modifiers: [.command])

                    Button("Previous Right Panel Mode") {
                        model.cycleRightPanelModeBackward()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                    Button("Next Right Panel Mode") {
                        model.cycleRightPanelModeForward()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                }

                CommandMenu("Layout") {
                    Button("Toggle Sidebar") {
                        model.toggleSidebarCollapsed()
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])

                    Button("Toggle Right Panel") {
                        model.toggleRightPanelCollapsed()
                    }
                    .keyboardShortcut("r", modifiers: [.command, .option])
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
            ?? JSONConfigurationStore.defaultPath()
    }

    private static func captureDirectory(environment: [String: String]) -> URL? {
        environment["YAAW_CAPTURE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentCLISessionBindingService.defaultCaptureDirectory()
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
