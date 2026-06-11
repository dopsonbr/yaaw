import SwiftUI
import YAAWKit

/// The global "Archived" disclosure: archived projects + threads in one flat,
/// restorable list. Consumes `WorkspaceStore`.
struct GlobalArchivedThreadsSection: View {
    let workspace: WorkspaceStore
    @Binding var isExpanded: Bool
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: (isExpanded
                            ? IconRole.disclosureExpanded : IconRole.disclosureCollapsed).icon
                            .systemSymbolName
                    )
                    .frame(width: 12)

                    Label("Archived", systemImage: IconRole.archive.icon.systemSymbolName)
                        .labelStyle(.titleAndIcon)

                    Spacer()

                    Text("\(workspace.archivedProjects.count + workspace.archivedThreads.count)")
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                }
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(dracula(.orange))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived")
            .accessibilityIdentifier("archived-section-toggle")

            if isExpanded {
                if workspace.archivedProjects.isEmpty && workspace.archivedThreads.isEmpty {
                    Text("Nothing archived")
                        .font(fonts.interfaceFont(sizeOffset: -1))
                        .foregroundStyle(dracula(.comment))
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(workspace.archivedProjects) { project in
                                ArchivedProjectRow(workspace: workspace, project: project)
                            }
                            ForEach(workspace.archivedThreads) { thread in
                                ArchivedThreadRow(
                                    workspace: workspace,
                                    thread: thread,
                                    onRenameThread: onRenameThread
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

struct ArchivedProjectRow: View {
    let workspace: WorkspaceStore
    let project: Project
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let isSelected = workspace.selectedProjectID == project.id
        let showActions = hovering || isSelected
        return HStack(spacing: 8) {
            Button {
                workspace.unarchiveProject(id: project.id)
            } label: {
                HStack(spacing: 6) {
                    if project.isPinned {
                        Image(systemName: IconRole.pinned.icon.systemSymbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(dracula(.pink))
                    }
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dracula(.comment))
                    Text(project.displayName)
                        .lineLimit(1)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived project \(project.displayName)")

            SidebarActionsMenu(help: "Archived project actions") {
                Button("Unarchive Project") { workspace.unarchiveProject(id: project.id) }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .font(fonts.interfaceFont(sizeOffset: -1))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
        )
        .padding(.horizontal, ChromeMetrics.rowHInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project.rootDirectory.path)
    }
}

struct ArchivedThreadRow: View {
    let workspace: WorkspaceStore
    let thread: AgentThread
    let onRenameThread: (AgentThread) -> Void
    @Environment(\.fontSettings) private var fonts
    @State private var hovering = false

    var body: some View {
        let isSelected = workspace.selectedThreadID == thread.id
        let showActions = hovering || isSelected
        return HStack(spacing: 8) {
            Button {
                workspace.selectThread(id: thread.id)
            } label: {
                HStack(spacing: 6) {
                    if thread.isPinned {
                        Image(systemName: IconRole.pinned.icon.systemSymbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(dracula(.pink))
                    }
                    Text(thread.displayName)
                        .lineLimit(1)
                    Spacer()
                    AgentCLIIcon(agentCLI: thread.agentCLI)
                        .frame(width: 16, height: 16)
                        .help(thread.agentCLI.displayName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived thread \(thread.displayName)")

            SidebarActionsMenu(help: "Archived thread actions") {
                Button("Rename Thread...") { onRenameThread(thread) }
                Button(thread.isPinned ? "Unpin Thread" : "Pin Thread") {
                    workspace.toggleThreadPinned(id: thread.id)
                }
                Button("Unarchive Thread") { workspace.unarchiveThread(id: thread.id) }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .font(fonts.interfaceFont(sizeOffset: -1))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: hovering))
        )
        .padding(.horizontal, ChromeMetrics.rowHInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(workspace.projectDisplayName(for: thread.projectID))
    }
}
