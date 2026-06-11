import Foundation
import YAAWKit

extension E2ERunner {
    /// Loaded unbound threads (no `sessionIdentity`) must require an explicit
    /// session link before launching, support a manual link that resumes the
    /// chosen identity, and support an explicit "start fresh" that launches a new
    /// session. SQLite stores default `requiresSessionLinkForLoadedUnboundThreads`
    /// to `true`, so building the stores triggers the reconcile.
    func assertUnboundThreadLinkRecovery() async throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("unbound-thread-link.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        let stores = try await makeStores(
            databasePath: databasePath,
            seed: unboundSeed(
                projectID: projectID, threadID: threadID, threadName: "Legacy Thread"))
        let workspace = stores.workspace
        try e2eAssert(
            workspace.selectedThreadRequiresSessionLink, "unbound loaded thread required link")
        let unboundLaunch = await workspace.surfaceLaunch(for: .project(threadID: threadID))
        try e2eAssert(
            unboundLaunch == nil,
            "unbound loaded thread did not silently start a fresh session")

        let candidate = SessionLinkCandidate(
            identity: "codex-linked-e2e",
            displayName: "Linked E2E Session",
            agentCLI: .codex,
            workingDirectory: paths.projectDirectory,
            source: "fixture")
        workspace.linkSession(threadID: threadID, candidate: candidate)
        try e2eAssert(
            !workspace.selectedThreadRequiresSessionLink, "link selection cleared link state")
        let linkedLaunch = try e2eUnwrap(
            await workspace.surfaceLaunch(for: .project(threadID: threadID)),
            "linked project terminal surface")
        try e2eAssert(
            linkedLaunch.command.joined(separator: " ").contains("codex-linked-e2e"),
            "linked session resumed the selected identity")

        try await assertStartNewSessionLaunchesFresh()
    }

    private func assertStartNewSessionLaunchesFresh() async throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("unbound-start-fresh.sqlite")
        let projectID = UUID()
        let threadID = UUID()
        let stores = try await makeStores(
            databasePath: databasePath,
            seed: unboundSeed(projectID: projectID, threadID: threadID, threadName: "Start Fresh"))
        let workspace = stores.workspace
        try e2eAssert(
            workspace.selectedThreadRequiresSessionLink, "second unbound thread required link")
        workspace.startNewSessionForUnlinkedThread(threadID: threadID)
        let freshLaunch = try e2eUnwrap(
            await workspace.surfaceLaunch(for: .project(threadID: threadID)),
            "fresh project terminal surface")
        try e2eAssert(
            !freshLaunch.command.joined(separator: " ").contains(" resume "),
            "explicit start-new action launched a fresh CLI session")
    }

    private func unboundSeed(projectID: UUID, threadID: UUID, threadName: String) -> YAAWSnapshot {
        YAAWSnapshot(
            projects: [
                Project(
                    id: projectID, displayName: "Unbound Project",
                    rootDirectory: paths.projectDirectory)
            ],
            threads: [
                AgentThread(
                    id: threadID, displayName: threadName, projectID: projectID,
                    workingDirectory: paths.projectDirectory, agentCLI: .codex)
            ],
            selectedProjectID: projectID,
            selectedThreadID: threadID,
            selectedRightPanelMode: .files,
            isGlobalTerminalExpanded: false)
    }
}
