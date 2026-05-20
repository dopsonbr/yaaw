import AgentIDEKit
import SwiftUI

@main
struct AgentIDEApp: App {
    @StateObject private var model = AppModel(store: SQLiteAgentIDEStore.defaultStore())

    var body: some Scene {
        WindowGroup("Agent IDE") {
            RootView(model: model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
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
        }
    }
}
