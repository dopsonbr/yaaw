import AppKit
import YAAWKit

@MainActor
final class AppShortcutPreflightMonitor {
    private weak var model: AppModel?
    private var monitor: Any?
    private let quitShortcut = KeyboardShortcutDefinition(key: "q", modifiers: [.command])
    private let appCommandActions = KeyboardShortcutAction.allCases.filter { $0.scope != .settings }

    func updateModel(_ model: AppModel) {
        self.model = model
        installIfNeeded()
    }

    func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }

        if quitShortcut.matches(event) {
            if performMenuKeyEquivalent(for: event) {
                return nil
            }
            NSApplication.shared.terminate(nil)
            return nil
        }

        guard event.yaawShortcutModifiers.contains(.command),
            let model,
            matchingAppCommandAction(for: event, model: model) != nil
        else {
            return event
        }

        _ = performMenuKeyEquivalent(for: event)
        return nil
    }

    private func matchingAppCommandAction(for event: NSEvent, model: AppModel)
        -> KeyboardShortcutAction?
    {
        appCommandActions.first { action in
            guard model.isKeyboardShortcutEnabled(for: action) else { return false }
            let definition = model.keyboardShortcutDefinition(for: action)
            return definition.modifiers.contains(.command) && definition.matches(event)
        }
    }

    private func performMenuKeyEquivalent(for event: NSEvent) -> Bool {
        NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
