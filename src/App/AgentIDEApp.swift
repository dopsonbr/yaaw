import AgentIDEKit
import SwiftUI

@main
struct AgentIDEApp: App {
    @StateObject private var model = AppModel()

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
        }
    }
}
