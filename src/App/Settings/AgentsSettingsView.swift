import SwiftUI
import YAAWKit

struct AgentsSettingsView: View {
    @Bindable var model: SettingsModel
    let agentCLIOptionCatalog: AgentCLIOptionCatalog
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                ForEach(AgentCLIKind.allCases) { kind in
                    SettingsGridRow(title: kind.displayName) {
                        agentLaunchDefaultsRow(for: kind)
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func agentLaunchDefaultsRow(for kind: AgentCLIKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                        .foregroundStyle(themeUI(.secondaryLabel))
                    TextField(kind.rawValue, text: model.agentCommandBinding(for: kind))
                        .textFieldStyle(.plain)
                        .font(fonts.interfaceFont(sizeOffset: -1))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(dracula(.currentLine))
                        .foregroundStyle(themeUI(.controlForeground))
                        .frame(width: 170)
                        .accessibilityIdentifier("settings-\(kind.rawValue)-command-field")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions")
                        .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                        .foregroundStyle(themeUI(.secondaryLabel))
                    Picker("Permissions", selection: model.agentPermissionSelection(for: kind)) {
                        Text("CLI default").tag(AgentLaunchOptions.defaultPermissionModeID)
                        ForEach(permissionModes(for: kind)) { mode in
                            Text(mode.displayName).tag(mode.id)
                        }
                        if let customMode = customPermissionModeID(for: kind) {
                            Text("Custom: \(customMode)").tag(customMode)
                        }
                    }
                    .settingsMenuControl(maxWidth: 190)
                    .accessibilityIdentifier("settings-\(kind.rawValue)-permission-picker")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments")
                        .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                        .foregroundStyle(themeUI(.secondaryLabel))
                    TextField("--flag value", text: model.agentArgumentsBinding(for: kind))
                        .textFieldStyle(.plain)
                        .font(fonts.interfaceFont(sizeOffset: -1))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(dracula(.currentLine))
                        .foregroundStyle(themeUI(.controlForeground))
                        .frame(width: 220)
                        .accessibilityIdentifier("settings-\(kind.rawValue)-arguments-field")
                }

                Button("Save") {
                    model.saveAgentLaunchSettings(for: kind)
                }
                .padding(.top, 19)
                .accessibilityIdentifier("settings-\(kind.rawValue)-launch-save-button")
            }
        }
    }

    private func permissionModes(for kind: AgentCLIKind) -> [AgentPermissionMode] {
        agentCLIOptionCatalog.permissionPresets(for: kind)
    }

    private func customPermissionModeID(for kind: AgentCLIKind) -> String? {
        guard
            let modeID = model.currentConfiguration.agent.launchDefaults.defaults(for: kind)
                .permissionModeID,
            !permissionModes(for: kind).contains(where: { $0.id == modeID })
        else {
            return nil
        }
        return modeID
    }
}
