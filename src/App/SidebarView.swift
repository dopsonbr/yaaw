import SwiftUI
import YAAWKit

/// Project + thread navigator. Consumes `WorkspaceStore` (projects/threads/
/// selection/archive) and `ActivityStore` (per-thread status/preview/idle age).
/// Hover-only actions, drag-reorder, and the create/rename sheets live here.
struct SidebarView: View {
    let workspace: WorkspaceStore
    let activity: ActivityStore
    let layout: LayoutStore
    let settings: SettingsStore

    @State private var isProjectSheetPresented = false
    @State private var threadSheetProject: Project?
    @State private var renameThread: AgentThread?
    @State private var isArchiveExpanded = false
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "Projects",
                    actionTitle: "New",
                    systemImage: IconRole.newProject.icon.systemSymbolName,
                    accessibilityIdentifier: "new-project-button"
                ) {
                    isProjectSheetPresented = true
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(workspace.activeProjects) { project in
                            ProjectSidebarSection(
                                workspace: workspace,
                                activity: activity,
                                project: project,
                                onNewThread: { threadSheetProject = project },
                                onRenameThread: { renameThread = $0 }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            GlobalArchivedThreadsSection(
                workspace: workspace,
                isExpanded: $isArchiveExpanded,
                onRenameThread: { renameThread = $0 }
            )

            Button(action: layout.toggleSidebarCollapsed) {
                Label("Collapse Sidebar", systemImage: IconRole.sidebar.icon.systemSymbolName)
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.comment))
            .accessibilityIdentifier("collapse-sidebar-button")
        }
        .padding(18)
        .sheet(isPresented: $isProjectSheetPresented) {
            ProjectCreationSheet(workspace: workspace)
        }
        .sheet(item: $threadSheetProject) { project in
            ThreadChoiceSheet(workspace: workspace, settings: settings, project: project)
        }
        .sheet(item: $renameThread) { thread in
            ThreadRenameSheet(workspace: workspace, thread: thread)
        }
    }
}

struct ProjectSidebarSection: View {
    let workspace: WorkspaceStore
    let activity: ActivityStore
    let project: Project
    let onNewThread: () -> Void
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let isSelected = workspace.selectedProjectID == project.id
        let showActions = hovering || isSelected
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SidebarIconButton(
                    systemImage: (workspace.isProjectExpanded(project.id)
                        ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed).icon
                        .systemSymbolName,
                    help: workspace.isProjectExpanded(project.id)
                        ? "Collapse project" : "Expand project",
                    weight: .regular
                ) {
                    workspace.setProjectExpanded(
                        project.id, isExpanded: !workspace.isProjectExpanded(project.id))
                }

                Button {
                    workspace.selectProject(id: project.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if project.isPinned {
                                Image(systemName: IconRole.pinned.icon.systemSymbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(dracula(.pink))
                            }
                            Text(project.displayName)
                                .font(fonts.interfaceFont(sizeOffset: 1, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(project.rootDirectory.path)
                            .font(fonts.interfaceFont(sizeOffset: -1))
                            .foregroundStyle(dracula(.comment))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project \(project.displayName)")
                .accessibilityIdentifier("project-row-\(project.id.uuidString)")

                SidebarIconButton(
                    systemImage: IconRole.newThread.icon.systemSymbolName, help: "New thread"
                ) {
                    onNewThread()
                }
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
                .accessibilityIdentifier("project-new-thread-button")

                SidebarActionsMenu(help: "Project actions") {
                    Button(project.isPinned ? "Unpin Project" : "Pin Project") {
                        workspace.toggleProjectPinned(id: project.id)
                    }
                    if workspace.canArchiveProject(id: project.id) {
                        Button("Archive Project") {
                            workspace.archiveProject(id: project.id)
                        }
                    }
                }
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                    .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
            )
            .padding(.horizontal, ChromeMetrics.rowHInset)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .draggable(project.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let rawID = items.first, let draggedProjectID = UUID(uuidString: rawID)
                else { return false }
                workspace.reorderProject(id: draggedProjectID, before: project.id)
                return true
            }

            if workspace.isProjectExpanded(project.id) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(workspace.activeThreads(for: project.id)) { thread in
                        ActiveThreadRow(
                            workspace: workspace,
                            activity: activity,
                            thread: thread,
                            onRenameThread: onRenameThread
                        )
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

struct ActiveThreadRow: View {
    let workspace: WorkspaceStore
    let activity: ActivityStore
    let thread: AgentThread
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let activityState = activity.threadActivity(for: thread.id)
        let isSelected = workspace.selectedThreadID == thread.id
        let showActions = hovering || isSelected
        return HStack(spacing: 6) {
            Button {
                workspace.selectThread(id: thread.id)
            } label: {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if thread.isPinned {
                                Image(systemName: IconRole.pinned.icon.systemSymbolName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(dracula(.pink))
                            }
                            Text(thread.displayName)
                                .font(
                                    fonts.interfaceFont(
                                        weight: activityState.isUnread ? .semibold : .regular)
                                )
                                .lineLimit(1)
                        }
                        if let preview = activityState.preview {
                            Text(preview)
                                .font(fonts.interfaceFont(sizeOffset: -2))
                                .foregroundStyle(
                                    activityState.isUnread ? dracula(.yellow) : dracula(.comment)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer()

                    if activityState.status == .inactive {
                        ThreadIdleAgeLabel(date: activity.lastInteractionDate(for: thread))
                            .frame(minWidth: 32, alignment: .trailing)
                    } else {
                        ThreadActivityIndicator(activity: activityState)
                            .frame(width: 16, height: 16)
                    }

                    AgentCLIIcon(agentCLI: thread.agentCLI)
                        .frame(width: 18, height: 18)
                        .help(thread.agentCLI.displayName)
                        .accessibilityLabel(thread.agentCLI.displayName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Thread \(thread.displayName), \(thread.agentCLI.displayName), \(activityState.status.rawValue)"
            )
            .accessibilityIdentifier("thread-row-\(thread.id.uuidString)")

            SidebarActionsMenu(help: "Thread actions") {
                Button("Rename Thread...") { onRenameThread(thread) }
                Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") {
                    workspace.toggleThreadPinned(id: thread.id)
                }
                Button("Archive Thread") { workspace.archiveThread(id: thread.id) }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .font(fonts.interfaceFont())
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
        )
        .padding(.horizontal, ChromeMetrics.rowHInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ThreadIdleAgeLabel: View {
    let date: Date
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let elapsed = ThreadRelativeTimeFormatter.shortElapsed(since: date, now: context.date)
            Text(elapsed)
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(dracula(.comment))
                .lineLimit(1)
                .help("Inactive for \(elapsed)")
                .accessibilityLabel("Inactive for \(elapsed)")
        }
    }
}

struct ThreadActivityIndicator: View {
    let activity: ThreadActivityState

    var body: some View {
        switch activity.status {
        case .working:
            ProgressView()
                .controlSize(.small)
                .tint(dracula(.cyan))
                .help("Working")
        case .needsInput:
            Image(
                systemName: activity.isUnread
                    ? "exclamationmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.system(size: ChromeMetrics.statusGlyph, weight: ChromeMetrics.glyphWeight))
            .foregroundStyle(dracula(.yellow))
            .help("Needs input")
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: ChromeMetrics.statusGlyph, weight: ChromeMetrics.glyphWeight))
                .foregroundStyle(dracula(.green))
                .help("Complete")
        case .inactive:
            Image(systemName: "circle")
                .font(.system(size: ChromeMetrics.statusGlyph, weight: ChromeMetrics.glyphWeight))
                .foregroundStyle(dracula(.comment))
                .help("Inactive")
        }
    }
}

struct SectionHeader: View {
    let title: String
    let actionTitle: String
    let systemImage: String
    var accessibilityIdentifier: String?
    let action: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        HStack {
            Text(title)
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.comment))

            Spacer()

            Button(action: action) {
                Label(actionTitle, systemImage: systemImage)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
            .foregroundStyle(dracula(.cyan))
            .help(actionTitle)
            .accessibilityLabel("\(actionTitle) \(title)")
            .accessibilityIdentifier(accessibilityIdentifier ?? "section-action-\(title)")
        }
    }
}

struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    var weight: Font.Weight = ChromeMetrics.glyphWeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: ChromeMetrics.sidebarButton, height: ChromeMetrics.sidebarButton)
        }
        .buttonStyle(.plain)
        .font(.system(size: ChromeMetrics.sidebarGlyph, weight: weight))
        .foregroundStyle(dracula(.cyan))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SidebarActionsMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: IconRole.moreActions.icon.systemSymbolName)
                .frame(width: ChromeMetrics.sidebarButton, height: ChromeMetrics.sidebarButton)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .font(.system(size: ChromeMetrics.sidebarGlyph, weight: ChromeMetrics.glyphWeight))
        .foregroundStyle(dracula(.cyan))
        .help(help)
        .accessibilityLabel(help)
    }
}
