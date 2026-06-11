import AppKit
import SwiftUI
import YAAWKit

/// New-project modal: directory picker + display name, with inline error.
/// Consumes `WorkspaceStore.createProject`.
struct ProjectCreationSheet: View {
    let workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var path = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Project")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(dracula(.purple))

            VStack(alignment: .leading, spacing: 8) {
                Text("Directory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dracula(.foreground))

                HStack(spacing: 10) {
                    Text(path.isEmpty ? "Select a project directory" : path)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(path.isEmpty ? dracula(.comment) : dracula(.foreground))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(dracula(.currentLine))

                    Button("Choose...") {
                        chooseDirectory()
                    }
                    .controlSize(.large)
                    .accessibilityLabel("Choose project directory")
                    .accessibilityIdentifier("new-project-choose-directory-button")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Display name")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dracula(.foreground))

                TextField("Defaults to selected directory name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .accessibilityLabel("Project display name")
                    .accessibilityIdentifier("new-project-name-field")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dracula(.red))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { createProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
                    .accessibilityIdentifier("new-project-create-button")
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL =
            path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = url.lastPathComponent
            }
            errorMessage = nil
        }
    }

    private func createProject() {
        do {
            try workspace.createProject(
                displayName: displayName,
                rootDirectory: URL(fileURLWithPath: path, isDirectory: true)
            )
            dismiss()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case WorkspaceStoreError.emptyProjectName:
            return "Project name is required."
        case WorkspaceStoreError.missingProjectDirectory(let path):
            return "Directory does not exist: \(path)"
        default:
            return "Project could not be created."
        }
    }
}

/// Thread rename modal. `requestThreadRename` is async (it consults the binding
/// actor for rename support), so the action runs in a Task and surfaces the
/// not-supported / empty-name errors inline.
struct ThreadRenameSheet: View {
    let workspace: WorkspaceStore
    let thread: AgentThread
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var errorMessage: String?
    @State private var isRenaming = false
    @Environment(\.fontSettings) private var fonts

    init(workspace: WorkspaceStore, thread: AgentThread) {
        self.workspace = workspace
        self.thread = thread
        _displayName = State(initialValue: thread.canonicalSessionName ?? thread.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Thread")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            Text(thread.agentCLI.displayName)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))

            TextField("Thread name", text: $displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(dracula(.currentLine))
                .foregroundStyle(dracula(.foreground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Thread name")
                .accessibilityIdentifier("rename-thread-name-field")

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { renameThread() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRenaming)
                    .accessibilityIdentifier("rename-thread-confirm-button")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.red))
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func renameThread() {
        isRenaming = true
        let name = displayName
        Task {
            do {
                try await workspace.requestThreadRename(id: thread.id, to: name)
                dismiss()
            } catch WorkspaceStoreError.sessionRenameNotSupported {
                errorMessage = "Rename is not available for \(thread.agentCLI.displayName)."
            } catch WorkspaceStoreError.emptyThreadName {
                errorMessage = "Enter a thread name."
            } catch {
                errorMessage = "Thread could not be renamed."
            }
            isRenaming = false
        }
    }
}
