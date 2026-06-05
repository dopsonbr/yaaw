import SwiftUI
import YAAWKit

struct ThreadChoiceSheet: View {
    @ObservedObject var model: AppModel
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontSettings) private var fonts
    @State private var displayName = ""
    @State private var selectedAgentCLI: AgentCLIKind
    @State private var executableName: String
    @State private var permissionModeID: String
    @State private var additionalArgumentsText: String
    @State private var errorMessage: String?

    init(model: AppModel, project: Project) {
        self.model = model
        self.project = project
        let initialAgent = model.defaultAgentCLI
        let initialOptions = model.configuredLaunchOptions(for: initialAgent)
        _selectedAgentCLI = State(initialValue: initialAgent)
        _executableName = State(
            initialValue: initialOptions.executableName
                ?? model.configuration.agentExecutableName(for: initialAgent)
        )
        _permissionModeID = State(
            initialValue: initialOptions.permissionModeID
                ?? AgentLaunchOptions.defaultPermissionModeID
        )
        _additionalArgumentsText = State(
            initialValue: AgentLaunchOptions.formatAdditionalArguments(
                initialOptions.additionalArguments)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                agentGrid
                detailsPanel
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                    .foregroundStyle(dracula(.red))
                    .accessibilityIdentifier("new-thread-error")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    createThread()
                } label: {
                    Label("Create", systemImage: IconRole.add.icon.systemSymbolName)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("new-thread-create-button")
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Thread")
                .font(fonts.interfaceFont(sizeOffset: 9, weight: .semibold))
                .foregroundStyle(dracula(.purple))
            Text(project.displayName)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
                .lineLimit(1)
        }
    }

    private var agentGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.fixed(156), spacing: 10),
                GridItem(.fixed(156), spacing: 10),
            ],
            spacing: 10
        ) {
            ForEach(AgentCLIKind.allCases) { agentCLI in
                AgentStartCard(
                    agentCLI: agentCLI,
                    isSelected: selectedAgentCLI == agentCLI,
                    isDefault: model.defaultAgentCLI == agentCLI,
                    commandSummary: commandSummary(for: agentCLI),
                    permissionSummary: permissionSummary(for: agentCLI),
                    argumentsSummary: argumentsSummary(for: agentCLI)
                ) {
                    selectAgent(agentCLI)
                }
                .accessibilityIdentifier("new-thread-card-\(agentCLI.rawValue)")
            }
        }
        .frame(width: 322)
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AgentCLIIcon(agentCLI: selectedAgentCLI)
                    .frame(width: 22, height: 22)
                Text(selectedAgentCLI.displayName)
                    .font(fonts.interfaceFont(sizeOffset: 2, weight: .semibold))
                if selectedAgentCLI == model.defaultAgentCLI {
                    Text("Default")
                        .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(dracula(.purple).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("new-thread-default-badge")
                }
            }

            field("Thread name") {
                TextField("Optional", text: $displayName)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("new-thread-name-field")
            }

            field("Command") {
                TextField(selectedAgentCLI.rawValue, text: $executableName)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("new-thread-command-field")
            }

            field("Permissions") {
                Picker("Permissions", selection: $permissionModeID) {
                    Text("CLI default").tag(AgentLaunchOptions.defaultPermissionModeID)
                    ForEach(permissionModes) { mode in
                        Text(mode.displayName).tag(mode.id)
                    }
                    if let customModeID {
                        Text("Custom: \(customModeID)").tag(customModeID)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("new-thread-permission-picker")
            }

            field("Extra args") {
                TextField("--flag value", text: $additionalArgumentsText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("new-thread-arguments-field")
            }
        }
        .padding(14)
        .frame(width: 372, alignment: .topLeading)
        .background(dracula(.currentLine).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                .foregroundStyle(dracula(.comment))
            content()
                .font(fonts.interfaceFont(sizeOffset: -1))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(dracula(.background))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var permissionModes: [AgentPermissionMode] {
        model.permissionModes(for: selectedAgentCLI)
    }

    private var customModeID: String? {
        guard
            permissionModeID != AgentLaunchOptions.defaultPermissionModeID,
            !permissionModes.contains(where: { $0.id == permissionModeID })
        else {
            return nil
        }
        return permissionModeID
    }

    private func selectAgent(_ agentCLI: AgentCLIKind) {
        selectedAgentCLI = agentCLI
        let options = model.configuredLaunchOptions(for: agentCLI)
        executableName =
            options.executableName ?? model.configuration.agentExecutableName(for: agentCLI)
        permissionModeID = options.permissionModeID ?? AgentLaunchOptions.defaultPermissionModeID
        additionalArgumentsText = AgentLaunchOptions.formatAdditionalArguments(
            options.additionalArguments
        )
        errorMessage = nil
    }

    private func commandSummary(for agentCLI: AgentCLIKind) -> String {
        model.configuredLaunchOptions(for: agentCLI).executableName
            ?? model.configuration.agentExecutableName(for: agentCLI)
    }

    private func permissionSummary(for agentCLI: AgentCLIKind) -> String {
        let options = model.configuredLaunchOptions(for: agentCLI)
        guard let modeID = options.permissionModeID else { return "CLI default" }
        return model.permissionModes(for: agentCLI).first { $0.id == modeID }?.displayName
            ?? modeID
    }

    private func argumentsSummary(for agentCLI: AgentCLIKind) -> String {
        let arguments = model.configuredLaunchOptions(for: agentCLI).additionalArguments
        guard !arguments.isEmpty else { return "No extra args" }
        return AgentLaunchOptions.formatAdditionalArguments(arguments)
    }

    private func createThread() {
        do {
            let additionalArguments =
                try AgentLaunchOptions.parseAdditionalArguments(additionalArgumentsText)
            let command = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
            let launchOptions = AgentLaunchOptions(
                executableName: command.isEmpty
                    ? model.configuration.agentExecutableName(for: selectedAgentCLI)
                    : command,
                permissionModeID: permissionModeID == AgentLaunchOptions.defaultPermissionModeID
                    ? nil
                    : permissionModeID,
                additionalArguments: additionalArguments
            )
            try model.createThread(
                projectID: project.id,
                agentCLI: selectedAgentCLI,
                displayName: displayName,
                launchOptions: launchOptions
            )
            dismiss()
        } catch is AgentLaunchOptionsArgumentError {
            errorMessage = "Arguments are not valid."
        } catch {
            errorMessage = "Thread could not be created."
        }
    }
}

private struct AgentStartCard: View {
    let agentCLI: AgentCLIKind
    let isSelected: Bool
    let isDefault: Bool
    let commandSummary: String
    let permissionSummary: String
    let argumentsSummary: String
    let action: () -> Void

    @Environment(\.fontSettings) private var fonts

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    AgentCLIIcon(agentCLI: agentCLI)
                        .frame(width: 20, height: 20)
                    Text(agentCLI.displayName)
                        .font(fonts.interfaceFont(sizeOffset: 1, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                if isDefault {
                    Text("Default")
                        .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                        .foregroundStyle(dracula(.yellow))
                        .accessibilityIdentifier("new-thread-default-badge-\(agentCLI.rawValue)")
                }

                summaryLine(commandSummary)
                summaryLine(permissionSummary)
                summaryLine(argumentsSummary)
            }
            .padding(10)
            .frame(width: 156, height: 140, alignment: .topLeading)
            .background(
                isSelected
                    ? AnyShapeStyle(dracula(.purple).opacity(0.34))
                    : AnyShapeStyle(dracula(.currentLine))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? dracula(.purple) : dracula(.background), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(agentCLI.displayName)")
    }

    private func summaryLine(_ text: String) -> some View {
        Text(text)
            .font(fonts.interfaceFont(sizeOffset: -2))
            .foregroundStyle(dracula(.comment))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
