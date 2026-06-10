import SwiftUI
import YAAWKit

struct ConfigFileSettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.settingsPath.path)
                .font(fonts.editorFont(sizeOffset: -1))
                .textSelection(.enabled)
                .foregroundStyle(dracula(.cyan))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Text("YAML")
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                    .foregroundStyle(dracula(.comment))

                if model.hasUnsavedChanges {
                    Text("Unsaved")
                        .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                        .foregroundStyle(dracula(.orange))
                }

                Spacer()
            }

            TextEditor(text: $model.editorText)
                .font(fonts.editorFont())
                .foregroundStyle(dracula(.foreground))
                .scrollContentBackground(.hidden)
                .background(dracula(.currentLine).opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            model.validationError == nil ? dracula(.currentLine) : dracula(.red),
                            lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .accessibilityLabel("Settings YAML editor")
                .accessibilityIdentifier("settings-yaml-editor")

            HStack {
                Button {
                    model.save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .configuredKeyboardShortcut(
                    model.currentConfiguration.shortcut(for: .saveSettings))
                .disabled(!model.hasUnsavedChanges)
                .accessibilityIdentifier("settings-save-button")

                Button {
                    model.requestReload()
                } label: {
                    Label("Reload", systemImage: IconRole.reload.icon.systemSymbolName)
                }
                .configuredKeyboardShortcut(
                    model.currentConfiguration.shortcut(for: .reloadSettings))
                .accessibilityIdentifier("settings-reload-button")

                Button {
                    model.revert()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .configuredKeyboardShortcut(
                    model.currentConfiguration.shortcut(for: .revertSettings))
                .disabled(!model.hasUnsavedChanges)
                .accessibilityIdentifier("settings-revert-button")

                Button {
                    model.openExternal()
                } label: {
                    Label(
                        "Open External",
                        systemImage: IconRole.openDocument.icon.systemSymbolName)
                }
                .configuredKeyboardShortcut(
                    model.currentConfiguration.shortcut(for: .openSettingsExternal))

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
