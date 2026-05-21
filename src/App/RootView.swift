import YAAWKit
import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
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

                    if !model.layoutState.isRightPanelCollapsed && geometry.size.width < rightPanelAdaptiveMinimumWidth {
                        CollapsedPanelRail(
                            systemImage: "sidebar.right",
                            accessibilityLabel: "Right panel hidden until the window is wider",
                            action: {}
                        )
                        .frame(width: 44)
                        .disabled(true)
                        .opacity(0.65)
                    } else if model.layoutState.isRightPanelCollapsed {
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

                BottomTerminalBar(
                    isExpanded: model.isBottomTerminalExpanded,
                    height: model.layoutState.globalTerminalHeight,
                    request: selectedBottomTerminalRequest,
                    onToggle: model.toggleBottomTerminal,
                    onResize: { delta in
                        model.setGlobalTerminalHeight(model.layoutState.globalTerminalHeight - delta)
                    },
                    onAppearExpanded: {
                        model.activateSelectedBottomTerminal()
                    }
                )
            }
        }
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
        .background(WindowTitleUpdater(title: model.windowTitle).frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            GhosttyTerminalRuntime.closeAll()
        }
    }

    private var selectedBottomTerminalRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return model.terminalLaunchRequest(for: .bottom(threadID: selectedThreadID))
    }
}

private let rightPanelAdaptiveMinimumWidth = 1_680.0

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var isProjectSheetPresented = false
    @State private var isThreadSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YAAW")
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
                    .accessibilityLabel("Project \(project.displayName)")
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
                    .accessibilityLabel("Thread \(thread.displayName), \(thread.agentCLI.displayName)")
                }

                if let selectedThreadID = model.selectedThreadID {
                    Button("Archive Selected Thread") {
                        model.archiveThread(id: selectedThreadID)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(dracula(.orange))
                    .padding(.top, 4)
                    .accessibilityLabel("Archive selected thread")
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
                .accessibilityLabel("\(actionTitle) \(title)")
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
            .accessibilityLabel("Archived thread \(thread.displayName)")

            Button(action: onUnarchive) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.cyan))
            .help("Unarchive")
            .accessibilityLabel("Unarchive \(thread.displayName)")
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
                .accessibilityLabel("Project display name")

            TextField("Directory path", text: $path)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Project directory path")

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
                ForEach(AgentCLIKind.allCases) { agentCLI in
                    Button(agentCLI.displayName) {
                        createThread(agentCLI: agentCLI)
                    }
                    .keyboardShortcut(agentCLI == AgentCLIKind.allCases.first ? .defaultAction : nil)
                    .accessibilityLabel("Create \(agentCLI.displayName) thread")
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
        VStack(alignment: .leading, spacing: 8) {
            if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
                MissingDirectoryBanner(
                    title: "Working directory is missing",
                    path: path,
                    message: "Project tools are paused until this directory exists again or a new thread uses another path."
                )
            } else if case .missing(let path) = model.selectedProjectDirectoryState {
                MissingDirectoryBanner(
                    title: "Project directory is missing",
                    path: path,
                    message: "Create a new project or restore the directory before creating more threads here."
                )
            }

            TerminalPlaceholderView(
                request: selectedProjectTerminalRequest,
                unavailableMessage: selectedProjectTerminalUnavailableMessage,
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
        }
        .padding(8)
        .background(dracula(.background))
    }

    private var selectedProjectTerminalRequest: TerminalLaunchRequest? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return model.terminalLaunchRequest(for: .project(threadID: selectedThreadID))
    }

    private var selectedProjectTerminalUnavailableMessage: String {
        if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
            return "Missing working directory: \(path)"
        }
        return model.projectTerminal.placeholderText
    }
}

private struct RightPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    model.toggleRightPanelCollapsed()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(dracula(.comment))
                .help("Collapse right panel")
                .accessibilityLabel("Collapse right panel")

                ForEach(RightPanelMode.allCases) { mode in
                    Button {
                        model.selectRightPanelMode(mode)
                    } label: {
                        Label(mode.displayName, systemImage: iconName(for: mode))
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(model.selectedRightPanelMode == mode ? dracula(.currentLine) : dracula(.background))
                    .foregroundStyle(model.selectedRightPanelMode == mode ? dracula(.pink) : dracula(.foreground))
                    .accessibilityLabel("\(mode.displayName) right panel")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

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
                    request: selectedRightPanelRequest,
                    unavailableMessage: selectedRightPanelUnavailableMessage(tool: "nvim")
                )
                    .id(model.selectedThreadID)
                    .onAppear {
                        model.activateSelectedRightPanelTerminal()
                    }

            case .git:
                TerminalPlaceholderView(
                    request: selectedRightPanelRequest,
                    unavailableMessage: selectedRightPanelUnavailableMessage(tool: "lazygit")
                )
                    .id(model.selectedThreadID)
                    .onAppear {
                        model.activateSelectedRightPanelTerminal()
                    }
            }
        }
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

    private func selectedRightPanelUnavailableMessage(tool: String) -> String {
        if case .missing(let path) = model.selectedThreadWorkingDirectoryState {
            return "Missing working directory for \(tool): \(path)"
        }
        return "Terminal unavailable for \(tool)"
    }

    private func iconName(for mode: RightPanelMode) -> String {
        switch mode {
        case .files:
            return "doc.on.doc"
        case .nvim:
            return "terminal"
        case .git:
            return "arrow.triangle.branch"
        }
    }
}

private struct MissingDirectoryBanner: View {
    let title: String
    let path: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(dracula(.orange))

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(dracula(.cyan))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Text(message)
                .font(.caption)
                .foregroundStyle(dracula(.foreground))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dracula(.currentLine))
        .accessibilityLabel("\(title): \(path)")
    }
}

private struct FileBrowserPanel: View {
    let state: FileBrowserState
    @Binding var searchQuery: String
    let onRefresh: () -> Void
    let onOpenFile: (FileBrowserEntry) -> Void
    @State private var expandedFolders: Set<String> = []
    @State private var typedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search files", text: $typedQuery)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .foregroundStyle(dracula(.foreground))
                    .accessibilityLabel("Search files")
                    .onAppear { typedQuery = searchQuery }
                    .onChange(of: searchQuery) { _, new in
                        if new != typedQuery { typedQuery = new }
                    }
                    .onChange(of: typedQuery) { _, new in
                        debounceTask?.cancel()
                        let captured = new
                        debounceTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                if searchQuery != captured { searchQuery = captured }
                            }
                        }
                    }

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(dracula(.cyan))
                .help("Refresh files")
                .accessibilityLabel("Refresh files")
            }

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
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ForEach(FileBrowserTreeBuilder.roots(from: state.visibleEntries)) { node in
                            FileBrowserTreeRow(
                                node: node,
                                depth: 0,
                                expandedFolders: $expandedFolders,
                                onOpenFile: onOpenFile
                            )
                        }
                    } else {
                        ForEach(state.visibleEntries) { entry in
                            FileBrowserSearchRow(entry: entry, onOpenFile: onOpenFile)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: state.entries) {
                seedExpandedFolders()
            }
            .onChange(of: state.rootPath) {
                expandedFolders.removeAll()
                seedExpandedFolders()
            }
            .onAppear {
                seedExpandedFolders()
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var statusText: String {
        guard let metadata = state.metadata else {
            return state.isIndexing ? "Indexing..." : "No index yet"
        }
        let ignored = metadata.ignoredDirectoryCount == 1 ? "1 ignored directory" : "\(metadata.ignoredDirectoryCount) ignored directories"
        return "\(state.visibleEntries.count) of \(metadata.fileCount) items, \(ignored)"
    }

    private func seedExpandedFolders() {
        expandedFolders = Set(
            state.entries
                .filter { $0.isDirectory && !$0.relativePath.contains("/") }
                .map(\.relativePath)
        )
    }
}

private struct FileBrowserTreeRow: View {
    let node: FileBrowserTreeNode
    let depth: Int
    @Binding var expandedFolders: Set<String>
    let onOpenFile: (FileBrowserEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if node.entry.isDirectory {
                    toggleExpanded()
                } else {
                    onOpenFile(node.entry)
                }
            } label: {
                FileBrowserRowContent(
                    entry: node.entry,
                    displayName: node.displayName,
                    depth: depth,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .help(node.entry.isDirectory ? node.entry.relativePath : "Open in nvim")

            if node.entry.isDirectory && isExpanded {
                ForEach(node.children) { child in
                    FileBrowserTreeRow(
                        node: child,
                        depth: depth + 1,
                        expandedFolders: $expandedFolders,
                        onOpenFile: onOpenFile
                    )
                }
            }
        }
    }

    private var isExpanded: Bool {
        expandedFolders.contains(node.entry.relativePath)
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedFolders.remove(node.entry.relativePath)
        } else {
            expandedFolders.insert(node.entry.relativePath)
        }
    }
}

private struct FileBrowserSearchRow: View {
    let entry: FileBrowserEntry
    let onOpenFile: (FileBrowserEntry) -> Void

    var body: some View {
        if entry.isDirectory {
            FileBrowserRowContent(
                entry: entry,
                displayName: entry.relativePath,
                depth: 0,
                isExpanded: false
            )
        } else {
            Button {
                onOpenFile(entry)
            } label: {
                FileBrowserRowContent(
                    entry: entry,
                    displayName: entry.relativePath,
                    depth: 0,
                    isExpanded: false
                )
            }
            .buttonStyle(.plain)
            .help("Open in nvim")
        }
    }
}

private struct FileBrowserRowContent: View {
    let entry: FileBrowserEntry
    let displayName: String
    let depth: Int
    var isExpanded = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dracula(.comment))
                .frame(width: 12)
                .opacity(entry.isDirectory ? 1 : 0)

            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(dracula(entry.isDirectory ? .cyan : .purple))
                .frame(width: 15)

            Text(displayName)
                .font(.system(.caption, design: .default).weight(entry.isDirectory ? .semibold : .regular))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("\(entry.isDirectory ? "Folder" : "File") \(entry.relativePath)")
    }
}

private struct TerminalPlaceholderView: View {
    let request: TerminalLaunchRequest?
    let unavailableMessage: String
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let request {
                GhosttyTerminalSurfaceView(request: request, onTitleChange: onTitleChange)
                    .accessibilityLabel("\(request.title) terminal")
            } else {
                Text(unavailableMessage)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(dracula(.foreground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }
}

private struct BottomTerminalBar: View {
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
                    accessibilityLabel: "Resize bottom terminal",
                    onDrag: onResize
                )
            }

            Button(action: onToggle) {
                HStack {
                    Text("Bottom Terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(dracula(.purple))

                    Spacer()

                    Text(isExpanded ? "Expanded" : "Collapsed")
                        .font(.caption)
                        .foregroundStyle(dracula(.comment))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse bottom terminal" : "Expand bottom terminal")

            if isExpanded {
                TerminalPlaceholderView(
                    request: request,
                    unavailableMessage: "Terminal unavailable for the selected thread"
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

private struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateTitle(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateTitle(from: nsView)
    }

    private func updateTitle(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
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
