import AgentIDEKit
import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.layoutState.isSidebarCollapsed {
                    CollapsedPanelRail(
                        systemImage: "sidebar.left",
                        accessibilityLabel: "Expand sidebar",
                        action: model.toggleSidebarCollapsed
                    )
                    .frame(width: 44)
                } else {
                    SidebarView(model: model)
                        .frame(width: model.layoutState.sidebarWidth)

                    VerticalResizeHandle(
                        accessibilityLabel: "Resize sidebar",
                        onDrag: { delta in
                            model.setSidebarWidth(model.layoutState.sidebarWidth + delta)
                        }
                    )
                }

                Divider()
                    .overlay(dracula(.currentLine))

                MainWorkspaceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .overlay(dracula(.currentLine))

                if model.layoutState.isRightPanelCollapsed {
                    CollapsedPanelRail(
                        systemImage: "sidebar.right",
                        accessibilityLabel: "Expand right panel",
                        action: model.toggleRightPanelCollapsed
                    )
                    .frame(width: 44)
                } else {
                    VerticalResizeHandle(
                        accessibilityLabel: "Resize right panel",
                        onDrag: { delta in
                            model.setRightPanelWidth(model.layoutState.rightPanelWidth - delta)
                        }
                    )

                    RightPanelView(model: model)
                        .frame(width: model.layoutState.rightPanelWidth)
                }
            }

            GlobalTerminalBar(
                isExpanded: model.isGlobalTerminalExpanded,
                height: model.layoutState.globalTerminalHeight,
                request: model.terminalLaunchRequest(for: .global),
                onToggle: model.toggleGlobalTerminal,
                onResize: { delta in
                    model.setGlobalTerminalHeight(model.layoutState.globalTerminalHeight - delta)
                },
                onAppearExpanded: {
                    model.activateGlobalTerminal()
                }
            )
        }
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            GhosttyTerminalRuntime.closeAll()
        }
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
                SectionHeader(
                    title: "Projects",
                    actionTitle: "New",
                    systemImage: "folder.badge.plus"
                ) {
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
                SectionHeader(
                    title: "Threads",
                    actionTitle: "New",
                    systemImage: "plus.message"
                ) {
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

            DisclosureGroup {
                if model.archivedThreadsForSelectedProject.isEmpty {
                    Text("No archived threads")
                        .font(.caption)
                        .foregroundStyle(dracula(.comment))
                        .padding(.vertical, 4)
                } else {
                    ForEach(model.archivedThreadsForSelectedProject) { thread in
                        ArchivedThreadRow(thread: thread) {
                            model.selectThread(id: thread.id)
                        } onUnarchive: {
                            model.unarchiveThread(id: thread.id)
                        }
                    }
                }
            } label: {
                Label("Archived", systemImage: "archivebox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.orange))
            }

            Spacer()

            Button {
                model.toggleSidebarCollapsed()
            } label: {
                Label("Collapse Sidebar", systemImage: "sidebar.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.comment))
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
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(dracula(.comment))

            Spacer()

            Button(action: action) {
                Label(actionTitle, systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(dracula(.cyan))
                .help(actionTitle)
        }
    }
}

private struct ArchivedThreadRow: View {
    let thread: AgentThread
    let onSelect: () -> Void
    let onUnarchive: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                Text(thread.displayName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onUnarchive) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.cyan))
            .help("Unarchive")
        }
        .padding(.vertical, 6)
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
    private let capturePoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                request: selectedProjectTerminalRequest,
                unavailableMessage: model.projectTerminal.placeholderText,
                onTitleChange: { role, title in
                    if case .project(let threadID) = role {
                        model.recordAgentCLITerminalTitle(threadID: threadID, title: title)
                    }
                }
            )
            .id(model.selectedThreadID)
            .onAppear {
                model.activateSelectedProjectTerminal()
            }
            .onReceive(capturePoll) { _ in
                model.pollSelectedAgentCLICaptureLog()
            }

            Spacer()
        }
        .padding(24)
        .background(dracula(.background))
    }

    private var selectedProjectTerminalRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return model.terminalLaunchRequest(for: .project(threadID: selectedThreadID))
    }
}

private struct RightPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    model.toggleRightPanelCollapsed()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(dracula(.comment))
                .help("Collapse right panel")

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
                FileBrowserPanel(
                    state: model.fileBrowserState,
                    searchQuery: Binding(
                        get: { model.fileBrowserState.searchQuery },
                        set: { model.updateFileSearchQuery($0) }
                    ),
                    onRefresh: model.refreshSelectedFileBrowser,
                    onOpenFile: { entry in
                        model.openFileInNvim(relativePath: entry.relativePath)
                    }
                )
                .onAppear {
                    model.refreshSelectedFileBrowser()
                }
                .onChange(of: model.selectedThreadID) {
                    model.refreshSelectedFileBrowser()
                }

            case .nvim:
                TerminalPlaceholderView(
                    title: "nvim",
                    request: selectedRightPanelRequest,
                    unavailableMessage: "Terminal unavailable for nvim"
                )
                    .id(model.selectedThreadID)
                    .onAppear {
                        model.activateSelectedRightPanelTerminal()
                    }

            case .git:
                TerminalPlaceholderView(
                    title: "Git",
                    request: selectedRightPanelRequest,
                    unavailableMessage: "Terminal unavailable for lazygit"
                )
                    .id(model.selectedThreadID)
                    .onAppear {
                        model.activateSelectedRightPanelTerminal()
                    }
            }

            Spacer()
        }
        .padding(18)
        .background(dracula(.background))
    }

    private var selectedRightPanelRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        switch model.selectedRightPanelMode {
        case .files:
            return nil
        case .nvim:
            return model.terminalLaunchRequest(for: .nvim(threadID: selectedThreadID))
        case .git:
            return model.terminalLaunchRequest(for: .lazygit(threadID: selectedThreadID))
        }
    }
}

private struct FileBrowserPanel: View {
    let state: FileBrowserState
    @Binding var searchQuery: String
    let onRefresh: () -> Void
    let onOpenFile: (FileBrowserEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Files")
                    .font(.headline)

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(dracula(.cyan))
                .help("Refresh files")
                .accessibilityLabel("Refresh files")
            }

            if let rootPath = state.rootPath {
                Text(rootPath)
                    .font(.caption)
                    .foregroundStyle(dracula(.comment))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Working directory \(rootPath)")
            }

            TextField("Search files", text: $searchQuery)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(dracula(.currentLine))
                .foregroundStyle(dracula(.foreground))
                .accessibilityLabel("Search files")

            HStack(spacing: 6) {
                if state.isIndexing {
                    ProgressView()
                        .scaleEffect(0.55)
                        .controlSize(.small)
                        .accessibilityLabel("Indexing files")
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(dracula(.comment))
                    .lineLimit(1)
            }

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(dracula(.orange))
                    .lineLimit(3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(state.visibleEntries) { entry in
                        FileBrowserRow(entry: entry, onOpenFile: onOpenFile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var statusText: String {
        guard let metadata = state.metadata else {
            return state.isIndexing ? "Indexing..." : "No index yet"
        }
        let ignored = metadata.ignoredDirectoryCount == 1 ? "1 ignored directory" : "\(metadata.ignoredDirectoryCount) ignored directories"
        return "\(state.visibleEntries.count) of \(metadata.fileCount) items, \(ignored)"
    }
}

private struct FileBrowserRow: View {
    let entry: FileBrowserEntry
    let onOpenFile: (FileBrowserEntry) -> Void

    var body: some View {
        if entry.isDirectory {
            rowContent
        } else {
            Button {
                onOpenFile(entry)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .help("Open in nvim")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(dracula(entry.isDirectory ? .cyan : .green))
                .frame(width: 16)

            Text(entry.relativePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .accessibilityLabel("\(entry.isDirectory ? "Folder" : "File") \(entry.relativePath)")
    }
}

private struct TerminalPlaceholderView: View {
    let title: String
    let request: TerminalLaunchRequest?
    let unavailableMessage: String
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(dracula(.green))

            if let request {
                GhosttyTerminalSurfaceView(request: request, onTitleChange: onTitleChange)
                    .accessibilityLabel("\(title) terminal")
            } else {
                Text(unavailableMessage)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(dracula(.foreground))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(dracula(.currentLine))
    }
}

private struct GlobalTerminalBar: View {
    let isExpanded: Bool
    let height: Double
    let request: TerminalLaunchRequest?
    let onToggle: () -> Void
    let onResize: (Double) -> Void
    let onAppearExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                HorizontalResizeHandle(
                    accessibilityLabel: "Resize global terminal",
                    onDrag: onResize
                )
            }

            Button(action: onToggle) {
                HStack {
                    Text("Global Terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(dracula(.purple))

                    Spacer()

                    Text(isExpanded ? "Expanded" : "Collapsed")
                        .font(.caption)
                        .foregroundStyle(dracula(.comment))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse global terminal" : "Expand global terminal")

            if isExpanded {
                TerminalPlaceholderView(
                    title: "Global",
                    request: request,
                    unavailableMessage: "Terminal unavailable for the user home directory"
                )
                    .frame(height: height)
                    .onAppear(perform: onAppearExpanded)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, isExpanded ? 0 : 10)
        .padding(.bottom, 10)
        .background(dracula(.currentLine))
    }
}

private struct CollapsedPanelRail: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        VStack {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.cyan))
            .help(accessibilityLabel)
            .accessibilityLabel(accessibilityLabel)

            Spacer()
        }
        .padding(.vertical, 14)
        .background(dracula(.background))
    }
}

private struct VerticalResizeHandle: View {
    let accessibilityLabel: String
    let onDrag: (Double) -> Void
    @State private var previousTranslation = 0.0

    var body: some View {
        Rectangle()
            .fill(dracula(.currentLine))
            .frame(width: 6)
            .overlay(Rectangle().fill(dracula(.comment)).frame(width: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let current = value.translation.width
                        onDrag(current - previousTranslation)
                        previousTranslation = current
                    }
                    .onEnded { _ in
                        previousTranslation = 0
                    }
            )
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct HorizontalResizeHandle: View {
    let accessibilityLabel: String
    let onDrag: (Double) -> Void
    @State private var previousTranslation = 0.0

    var body: some View {
        Rectangle()
            .fill(dracula(.currentLine))
            .frame(height: 6)
            .overlay(Rectangle().fill(dracula(.comment)).frame(height: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let current = value.translation.height
                        onDrag(current - previousTranslation)
                        previousTranslation = current
                    }
                    .onEnded { _ in
                        previousTranslation = 0
                    }
            )
            .accessibilityLabel(accessibilityLabel)
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
