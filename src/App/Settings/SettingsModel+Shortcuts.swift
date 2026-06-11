import YAAWKit

extension SettingsModel {
    // MARK: - Keyboard shortcuts

    func updateShortcut(_ action: KeyboardShortcutAction, key: String) {
        var definition = currentConfiguration.shortcut(for: action)
        definition.key = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
        saveShortcut(definition, for: action)
    }

    func toggleShortcutModifier(
        _ modifier: KeyboardShortcutModifier, for action: KeyboardShortcutAction
    ) {
        var definition = currentConfiguration.shortcut(for: action)
        if definition.modifiers.contains(modifier) {
            definition.modifiers.removeAll { $0 == modifier }
        } else {
            definition.modifiers.append(modifier)
        }
        saveShortcut(definition, for: action)
    }

    func saveShortcut(
        _ definition: KeyboardShortcutDefinition, for action: KeyboardShortcutAction
    ) {
        do {
            var nextConfiguration = try dependencies.validateText(editorText)
            nextConfiguration.keyboardShortcuts.setDefinition(definition, for: action)
            nextConfiguration = nextConfiguration.validated()
            let conflicts = nextConfiguration.keyboardShortcuts.duplicateActions()
            if conflicts.contains(action) {
                validationError =
                    "Shortcut conflict: \(definition.displayText) is already used by another action."
                statusMessage = "Shortcut was not changed."
                return
            }
            let renderedText = YAMLConfigurationStore.render(nextConfiguration)
            _ = try dependencies.saveText(renderedText)
            editorText = renderedText
            lastSavedText = renderedText
            currentConfiguration = nextConfiguration
            selectedThemeID = nextConfiguration.themeName
            globalChatsDirectoryText = nextConfiguration.projects.globalChatsDirectory
            syncAgentLaunchTextFields(with: nextConfiguration)
            validationError = nil
            statusMessage = "Shortcut saved and applied."
        } catch {
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Shortcut was not changed."
        }
    }
}
