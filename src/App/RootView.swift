import AgentIDEKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 250)

                Divider()
                    .overlay(dracula(.currentLine))

                MainWorkspaceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .overlay(dracula(.currentLine))

                RightPanelView(model: model)
                    .frame(width: 300)
            }

            GlobalTerminalBar(isExpanded: model.isGlobalTerminalExpanded)
        }
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var isProjectSheetPresented = false
    @State private var isThreadSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent IDE")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Projects", actionTitle: "New") {
                    isProjectSheetPresented = true
                }

                ForEach(model.projects) { project in
                    Button {
                        model.selectProject(id: project.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayName)
                                .lineLimit(1)

                            Text(project.rootDirectory.path)
                                .font(.caption)
                                .foregroundStyle(dracula(.comment))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(model.selectedProjectID == project.id ? dracula(.currentLine) : dracula(.background))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Threads", actionTitle: "New") {
                    isThreadSheetPresented = true
                }

                ForEach(model.activeThreadsForSelectedProject) { thread in
                    Button {
                        model.selectThread(id: thread.id)
                    } label: {
                        HStack {
                            Text(thread.displayName)
                                .lineLimit(1)

                            Spacer()

                            Text(thread.agentCLI.displayName)
                                .font(.caption)
                                .foregroundStyle(dracula(.cyan))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(model.selectedThreadID == thread.id ? dracula(.currentLine) : dracula(.background))
                }

                if let selectedThreadID = model.selectedThreadID {
                    Button("Archive Selected Thread") {
                        model.archiveThread(id: selectedThreadID)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(dracula(.orange))
                    .padding(.top, 4)
                }
            }

            if !model.archivedThreadsForSelectedProject.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Archived")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(dracula(.orange))

                    ForEach(model.archivedThreadsForSelectedProject) { thread in
                        Button {
                            model.selectThread(id: thread.id)
                        } label: {
                            Text(thread.displayName)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .padding(18)
        .background(dracula(.background))
        .sheet(isPresented: $isProjectSheetPresented) {
            ProjectCreationSheet(model: model)
        }
        .sheet(isPresented: $isThreadSheetPresented) {
            ThreadChoiceSheet(model: model)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(dracula(.comment))

            Spacer()

            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(dracula(.cyan))
        }
    }
}

private struct ProjectCreationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var path = NSHomeDirectory()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)

            TextField("Directory path", text: $path)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.red))
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Create") {
                    createProject()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(dracula(.background))
    }

    private func createProject() {
        do {
            try model.createProject(
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
        case AppModelError.emptyProjectName:
            return "Project name is required."
        case AppModelError.missingProjectDirectory(let path):
            return "Directory does not exist: \(path)"
        default:
            return "Project could not be created."
        }
    }
}

private struct ThreadChoiceSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Thread")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            Text(model.selectedProject?.displayName ?? "No project selected")
                .foregroundStyle(dracula(.comment))

            HStack(spacing: 12) {
                Button("Codex") {
                    createThread(agentCLI: .codex)
                }
                .keyboardShortcut(.defaultAction)

                Button("Claude") {
                    createThread(agentCLI: .claude)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.red))
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(dracula(.background))
    }

    private func createThread(agentCLI: AgentCLIKind) {
        do {
            try model.createThread(agentCLI: agentCLI)
            dismiss()
        } catch {
            errorMessage = "Thread could not be created."
        }
    }
}

private struct MainWorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedThread?.displayName ?? "Hello World Thread")
                    .font(.title.weight(.semibold))

                Text("SwiftPM native macOS scaffold")
                    .foregroundStyle(dracula(.comment))
            }

            TerminalPlaceholderView(
                title: model.projectTerminal.title,
                message: model.projectTerminal.placeholderText
            )

            Spacer()
        }
        .padding(24)
        .background(dracula(.background))
    }
}

private struct RightPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(RightPanelMode.allCases) { mode in
                    Button {
                        model.selectRightPanelMode(mode)
                    } label: {
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(model.selectedRightPanelMode == mode ? dracula(.currentLine) : dracula(.background))
                    .foregroundStyle(model.selectedRightPanelMode == mode ? dracula(.pink) : dracula(.foreground))
                }
            }

            Divider()
                .overlay(dracula(.currentLine))

            switch model.selectedRightPanelMode {
            case .files:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files")
                        .font(.headline)

                    ForEach(SampleFileBrowser.sampleEntries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.isDirectory ? "Folder" : "File")
                                .font(.caption)
                                .foregroundStyle(dracula(entry.isDirectory ? .cyan : .green))
                                .frame(width: 46, alignment: .leading)

                            Text(entry.relativePath)
                                .lineLimit(1)
                        }
                    }
                }

            case .nvim:
                TerminalPlaceholderView(title: "nvim", message: "Terminal placeholder for nvim")

            case .git:
                TerminalPlaceholderView(title: "Git", message: "Terminal placeholder for lazygit")
            }

            Spacer()
        }
        .padding(18)
        .background(dracula(.background))
    }
}

private struct TerminalPlaceholderView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(dracula(.green))

            Text(message)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(dracula(.foreground))

            Text("Hello World")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(dracula(.yellow))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(dracula(.currentLine))
    }
}

private struct GlobalTerminalBar: View {
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Global Terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.purple))

                Spacer()

                Text(isExpanded ? "Expanded" : "Collapsed")
                    .font(.caption)
                    .foregroundStyle(dracula(.comment))
            }

            if isExpanded {
                TerminalPlaceholderView(title: "Global", message: "Terminal placeholder for the user home directory")
                    .frame(height: 120)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(dracula(.currentLine))
    }
}

func dracula(_ role: DraculaRole) -> Color {
    Color(hex: DraculaTheme.hex(for: role))
}

private extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)

        self.init(
            red: Double((rgb >> 16) & 0xff) / 255.0,
            green: Double((rgb >> 8) & 0xff) / 255.0,
            blue: Double(rgb & 0xff) / 255.0
        )
    }
}
