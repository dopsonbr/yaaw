import AgentIDEKit
import SwiftUI

@main
struct AgentIDEApp: App {
    @StateObject private var model: AppModel
    private let startupError: Error?

    init() {
        do {
            let store = try SQLiteAgentIDEStore.defaultStore()
            _model = StateObject(wrappedValue: AppModel(store: store))
            startupError = nil
        } catch {
            _model = StateObject(wrappedValue: AppModel(store: InMemoryAgentIDEStore.helloWorld()))
            startupError = error
        }
    }

    var body: some Scene {
        WindowGroup("Agent IDE") {
            Group {
                if let startupError {
                    PersistenceStartupFailureView(
                        error: startupError,
                        databasePath: SQLiteAgentIDEStore.defaultDatabasePath()
                    )
                } else {
                    RootView(model: model)
                }
            }
            .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            if startupError == nil {
                CommandMenu("Terminal") {
                    Button("Toggle Global Terminal") {
                        model.toggleGlobalTerminal()
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
}

private struct PersistenceStartupFailureView: View {
    let error: Error
    let databasePath: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Agent IDE")
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
