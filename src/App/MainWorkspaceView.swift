import SwiftUI
import YAAWKit

/// The agent terminal for the selected thread, with missing-directory banners
/// and the session-link gate. Consumes `WorkspaceStore` (directory state /
/// session-link) + `ActivityStore` (background capture poll) and composites the
/// surface through `RenderHostClient`.
struct MainWorkspaceView: View {
    let workspace: WorkspaceStore
    let activity: ActivityStore
    @ObservedObject var renderHostClient: RenderHostClient
    let fonts: FontSettings

    private let capturePoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var isSessionLinkSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .missing(let path) = workspace.selectedThreadWorkingDirectoryState {
                MissingDirectoryBanner(
                    title: "Working directory is missing",
                    path: path,
                    message:
                        "Project tools are paused until this directory exists again or a new thread uses another path."
                )
            } else if case .missing(let path) = workspace.selectedProjectDirectoryState {
                MissingDirectoryBanner(
                    title: "Project directory is missing",
                    path: path,
                    message:
                        "Create a new project or restore the directory before creating more threads here."
                )
            }

            Group {
                if workspace.selectedThreadRequiresSessionLink {
                    SessionLinkRequiredView(
                        workspace: workspace,
                        onLink: { isSessionLinkSheetPresented = true },
                        onStartNew: startNewSelectedSession
                    )
                } else {
                    TerminalPlaceholderView(
                        client: renderHostClient,
                        role: workspace.selectedThreadID.map { .project(threadID: $0) },
                        title: workspace.selectedThread?.agentCLI.displayName ?? "Agent",
                        unavailableMessage: unavailableMessage,
                        fonts: fonts,
                        onActivate: activateSelectedProjectTerminal
                    )
                    .id(workspace.selectedThreadID)
                    .accessibilityIdentifier("project-terminal")
                }
            }
            .onReceive(capturePoll) { _ in
                Task { await activity.pollAgentCLIStateInBackground() }
            }
        }
        .padding(8)
        .background(dracula(.background))
        .sheet(isPresented: $isSessionLinkSheetPresented) {
            SessionLinkSheet(
                workspace: workspace,
                onResume: {
                    isSessionLinkSheetPresented = false
                    activateSelectedProjectTerminal()
                },
                onStartNew: {
                    isSessionLinkSheetPresented = false
                    startNewSelectedSession()
                }
            )
        }
    }

    private var unavailableMessage: String {
        if case .missing(let path) = workspace.selectedThreadWorkingDirectoryState {
            return "Missing working directory: \(path)"
        }
        return "Select a thread to start an agent terminal."
    }

    private func activateSelectedProjectTerminal() {
        guard let threadID = workspace.selectedThreadID else { return }
        workspace.activateTerminal(role: .project(threadID: threadID))
    }

    private func startNewSelectedSession() {
        guard let threadID = workspace.selectedThreadID else { return }
        workspace.startNewSessionForUnlinkedThread(threadID: threadID)
        workspace.activateTerminal(role: .project(threadID: threadID))
    }
}

/// Shown when a loaded unbound thread must be linked to a CLI session (or start
/// fresh) before its terminal launches.
struct SessionLinkRequiredView: View {
    let workspace: WorkspaceStore
    let onLink: () -> Void
    let onStartNew: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(workspace.selectedThread?.displayName ?? "Thread")
                .font(fonts.interfaceFont(sizeOffset: 5, weight: .semibold))
                .foregroundStyle(dracula(.foreground))
                .lineLimit(1)

            Text("Session link required")
                .font(fonts.interfaceFont(sizeOffset: 1, weight: .semibold))
                .foregroundStyle(dracula(.purple))

            HStack(spacing: 10) {
                Button("Link Session...", action: onLink)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("session-link-button")
                Button("Start New Session", action: onStartNew)
                    .accessibilityIdentifier("session-start-new-button")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
        .accessibilityIdentifier("session-link-required")
    }
}

/// Session-link picker. Candidates are loaded asynchronously from the binding
/// actor, so the list is fetched in a Task on appear.
struct SessionLinkSheet: View {
    let workspace: WorkspaceStore
    let onResume: () -> Void
    let onStartNew: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontSettings) private var fonts
    @State private var candidates: [SessionLinkCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link Session")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            if candidates.isEmpty {
                Text("No matching sessions found.")
                    .font(fonts.interfaceFont())
                    .foregroundStyle(dracula(.comment))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack(spacing: 10) {
                Button("Start New Session", action: onStartNew)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await loadCandidates() }
    }

    private func loadCandidates() async {
        guard let threadID = workspace.selectedThreadID else { return }
        candidates = await workspace.sessionLinkCandidates(for: threadID)
    }

    private func candidateRow(_ candidate: SessionLinkCandidate) -> some View {
        Button {
            guard let threadID = workspace.selectedThreadID else { return }
            workspace.linkSession(threadID: threadID, candidate: candidate)
            onResume()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.displayName)
                        .font(fonts.interfaceFont(weight: .semibold))
                        .foregroundStyle(dracula(.foreground))
                        .lineLimit(1)
                    Text(candidate.identity)
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(candidate.updatedAt.map(Self.shortDate) ?? candidate.source)
                        .font(fonts.interfaceFont(sizeOffset: -2))
                        .foregroundStyle(dracula(.comment))
                        .lineLimit(1)
                }
                Spacer()
                Text("Link & Resume")
                    .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                    .foregroundStyle(dracula(.cyan))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dracula(.currentLine))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Link \(candidate.displayName)")
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
