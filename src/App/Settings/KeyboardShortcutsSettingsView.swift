import SwiftUI
import YAAWKit

struct KeyboardShortcutsSettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search actions", text: $model.shortcutSearchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("settings-keybindings-search")

                Spacer()
            }

            HStack(spacing: 10) {
                Text("Action")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Scope")
                    .frame(width: 110, alignment: .leading)
                Text("Shortcut")
                    .frame(width: 180, alignment: .leading)
                Text("Default")
                    .frame(width: 150, alignment: .leading)
                Text("Modifiers")
                    .frame(width: 260, alignment: .leading)
                Text("")
                    .frame(width: 130)
            }
            .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
            .foregroundStyle(dracula(.comment))
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.filteredShortcutActions) { action in
                        SettingsKeyBindingRow(
                            action: action,
                            definition: model.currentConfiguration.shortcut(for: action),
                            isConflicting: model.currentConfiguration.keyboardShortcuts
                                .duplicateActions()
                                .contains(action),
                            onSetKey: { key in model.updateShortcut(action, key: key) },
                            onToggleModifier: { modifier in
                                model.toggleShortcutModifier(modifier, for: action)
                            },
                            onClear: { model.saveShortcut(.unbound, for: action) },
                            onReset: { model.saveShortcut(action.defaultShortcut, for: action) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .background(dracula(.background))
            .accessibilityIdentifier("settings-keybindings-list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
