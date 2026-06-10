import SwiftUI
import YAAWKit

struct GeneralSettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                SettingsGridRow(title: "Default agent") {
                    Picker("Default agent", selection: model.defaultAgentSelection) {
                        ForEach(AgentCLIKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .settingsMenuControl(maxWidth: 260)
                    .accessibilityIdentifier("settings-default-agent-picker")
                }

                SettingsGridRow(title: "Markdown/HTML") {
                    Picker(
                        "Markdown and HTML primary open",
                        selection: model.markdownHTMLDefaultSelection
                    ) {
                        Text("Preview").tag(FileBrowserMarkdownAndHTMLDefault.browserPreview)
                        Text("Editor").tag(FileBrowserMarkdownAndHTMLDefault.editor)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .accessibilityIdentifier("settings-markdown-html-open-picker")
                }

                SettingsGridRow(title: "CLI options") {
                    Button {
                        model.refreshAgentCLIOptions()
                    } label: {
                        Label("Refresh", systemImage: IconRole.reload.icon.systemSymbolName)
                    }
                    .accessibilityIdentifier("settings-refresh-cli-options-button")
                }

                SettingsGridRow(title: "Global chats") {
                    HStack(spacing: 8) {
                        TextField("Global chats directory", text: $model.globalChatsDirectoryText)
                            .textFieldStyle(.plain)
                            .font(fonts.interfaceFont(sizeOffset: -1))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(dracula(.currentLine))
                            .foregroundStyle(themeUI(.controlForeground))
                            .onSubmit(model.saveProjectSettings)
                            .accessibilityIdentifier("settings-global-chats-directory-field")

                        Button {
                            model.chooseGlobalChatsDirectory()
                        } label: {
                            Image(systemName: IconRole.openDocument.icon.systemSymbolName)
                                .frame(width: 28, height: 28)
                        }
                        .help("Choose global chats directory")
                        .accessibilityLabel("Choose global chats directory")

                        Button("Save") {
                            model.saveProjectSettings()
                        }
                        .disabled(
                            model.globalChatsDirectoryText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ) == model.currentConfiguration.projects.globalChatsDirectory)
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
