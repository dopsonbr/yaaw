import Foundation
import YAAWKit

extension E2ERunner {
    // MARK: - Missing lazygit → git diff fallback

    func assertMissingLazygitFallsBackToGitDiff() async throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("missing-lazygit.sqlite")
        var missingToolEnvironment = fixtures.environment
        missingToolEnvironment["PATH"] =
            paths.missingToolBinDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        let stores = try await makeStores(
            databasePath: databasePath, environment: missingToolEnvironment)
        try stores.workspace.createProject(
            displayName: "Missing Tool Project", rootDirectory: paths.projectDirectory)
        let threadID = try stores.workspace.createThread(agentCLI: .codex)
        stores.rightPanel.selectRightPanelMode(.git)
        let launch = try e2eUnwrap(
            await stores.workspace.surfaceLaunch(for: .lazygit(threadID: threadID)),
            "missing lazygit surface")
        try e2eAssert(
            launch.command == ["git", "--no-pager", "diff"]
                || launch.command == [
                    paths.missingToolBinDirectory.appendingPathComponent("git").path,
                    "--no-pager", "diff",
                ]
                || launch.command == ["/usr/bin/git", "--no-pager", "diff"],
            "missing lazygit fell back to git --no-pager diff")
    }

    // MARK: - Missing nvim → vim → vi fallback

    func assertMissingNvimFallsBackToVimThenVi() async throws {
        let databasePath = paths.stateDirectory.appendingPathComponent("missing-nvim.sqlite")
        let nvimPath = paths.missingToolBinDirectory.appendingPathComponent("nvim")
        if FileManager.default.fileExists(atPath: nvimPath.path) {
            try FileManager.default.removeItem(at: nvimPath)
        }
        var missingToolEnvironment = fixtures.environment
        missingToolEnvironment["PATH"] = paths.missingToolBinDirectory.path
        let stores = try await makeStores(
            databasePath: databasePath, environment: missingToolEnvironment)
        try stores.workspace.createProject(
            displayName: "Missing nvim Project", rootDirectory: paths.projectDirectory)
        let threadID = try stores.workspace.createThread(agentCLI: .codex)
        stores.rightPanel.openFileInNvim(relativePath: "README.md")

        let vimLaunch = try e2eUnwrap(
            await stores.workspace.surfaceLaunch(for: .nvim(threadID: threadID)),
            "missing nvim surface")
        try e2eAssert(
            Array(vimLaunch.command.suffix(2)) == [
                paths.missingToolBinDirectory.appendingPathComponent("vim").path, "README.md",
            ],
            "missing nvim fell back to vim")

        try FileManager.default.removeItem(
            at: paths.missingToolBinDirectory.appendingPathComponent("vim"))
        let viLaunch = try e2eUnwrap(
            await stores.workspace.surfaceLaunch(for: .nvim(threadID: threadID)),
            "missing nvim and vim surface")
        try e2eAssert(
            Array(viLaunch.command.suffix(2)) == [
                paths.missingToolBinDirectory.appendingPathComponent("vi").path, "README.md",
            ],
            "missing nvim and vim fell back to vi")
    }

    // MARK: - Image paste policy

    func assertImagePastePolicyUsesNativeShortcut() throws {
        let policy = TerminalImagePastePolicy()
        for cli in AgentCLIKind.allCases {
            let text = policy.textForImagePaste(agentCLI: cli)
            try e2eAssert(
                text == TerminalImagePastePolicy.nativeAttachmentShortcutText,
                "\(cli.displayName) image paste uses native attachment shortcut")
            try e2eAssert(
                !text.contains("Attached image:"),
                "\(cli.displayName) image paste avoids path formatter")
            try e2eAssert(
                !text.contains(paths.root.path),
                "\(cli.displayName) image paste does not expose sandbox path")
        }
    }

    // MARK: - Missing-directory recovery

    func assertMissingDirectoryRecovery() async throws {
        let databasePath = paths.stateDirectory.appendingPathComponent(
            "missing-directory-recovery.sqlite")
        let recoverableRoot = paths.root.appendingPathComponent(
            "recoverable-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoverableRoot, withIntermediateDirectories: true)
        let stores = try await makeStores(databasePath: databasePath)
        try stores.workspace.createProject(
            displayName: "Recoverable Project", rootDirectory: recoverableRoot)
        let threadID = try stores.workspace.createThread(agentCLI: .codex)
        await stores.activity.recordAgentCLIOutput(
            threadID: threadID,
            output:
                "YAAW_SESSION_ID=codex-missing-directory\nYAAW_SESSION_NAME=Missing Directory\n")
        await fixtures.flush(stores)
        try FileManager.default.removeItem(at: recoverableRoot)

        try e2eAssert(
            stores.workspace.selectedThreadWorkingDirectoryState
                == .missing(path: recoverableRoot.path),
            "deleted directory reported missing")
        let blockedLaunch = await stores.workspace.surfaceLaunch(for: .project(threadID: threadID))
        try e2eAssert(blockedLaunch == nil, "missing directory blocked terminal launch")
        stores.activity.refreshSelectedFileBrowser()
        try e2eAssert(
            stores.activity.fileBrowserState.errorMessage
                == "Missing working directory: \(recoverableRoot.path)",
            "missing directory surfaced in file browser")

        try FileManager.default.createDirectory(
            at: recoverableRoot, withIntermediateDirectories: true)
        try "restored\n".write(
            to: recoverableRoot.appendingPathComponent("RESTORED.md"),
            atomically: true, encoding: .utf8)
        let reloaded = try await makeStores(databasePath: databasePath)
        try e2eAssert(
            reloaded.workspace.selectedThreadWorkingDirectoryState
                == .available(path: recoverableRoot.path),
            "restored directory reported available after reload")
        let restoredLaunch = await reloaded.workspace.surfaceLaunch(
            for: .project(threadID: threadID))
        try e2eAssert(
            restoredLaunch != nil, "restored directory allowed terminal launch after reload")
    }

    // MARK: - Agent CLI metadata capture (binding actor, not stores)

    func assertAgentCLIMetadataCapture() async throws {
        let actor = fixtures.makeSessionBindingActor()
        let codex = try await actor.captureMetadataByRunningCLI(
            kind: .codex, workingDirectory: paths.projectDirectory,
            environment: fixtures.environment)
        try e2eAssert(
            codex.identity == "codex-e2e-001",
            "codex command double reported deterministic identity")
        let claude = try await actor.captureMetadataByRunningCLI(
            kind: .claude, resumeIdentity: "claude-e2e-001",
            workingDirectory: paths.projectDirectory, environment: fixtures.environment)
        try e2eAssert(
            claude.canonicalName == "Claude Resumed claude-e2e-001",
            "claude command double reported deterministic resume metadata")
        let opencode = try await actor.captureMetadataByRunningCLI(
            kind: .opencode, resumeIdentity: "opencode-e2e-001",
            workingDirectory: paths.projectDirectory, environment: fixtures.environment)
        try e2eAssert(
            opencode.canonicalName == "OpenCode Resumed opencode-e2e-001",
            "opencode command double reported deterministic resume metadata")
        let copilot = try await actor.captureMetadataByRunningCLI(
            kind: .copilot, resumeIdentity: "copilot-e2e-001",
            workingDirectory: paths.projectDirectory, environment: fixtures.environment)
        try e2eAssert(
            copilot.canonicalName == "Copilot Resumed copilot-e2e-001",
            "copilot command double reported deterministic resume metadata")
    }

    // MARK: - yaaw-notify helper invocation

    /// Installs (by building a throwaway launch descriptor, which installs the
    /// notify helper) and runs the yaaw-notify helper so the activity NDJSON log
    /// exists for the codex thread, exactly as the pre-rewrite runner did.
    func runYAAWNotify(threadID: UUID, status: String, title: String, body: String) async throws {
        let helperURL = paths.helperBinDirectory.appendingPathComponent("yaaw-notify")
        if !FileManager.default.isExecutableFile(atPath: helperURL.path) {
            let thread = AgentThread(
                displayName: "Fixture", projectID: UUID(),
                workingDirectory: paths.projectDirectory)
            _ = await fixtures.makeSessionBindingActor().terminalLaunchDescriptor(for: thread)
        }
        let eventLogURL = paths.activityDirectory.appendingPathComponent(
            "\(threadID.uuidString).ndjson")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--status", status, "--title", title, "--body", body]
        process.environment = [
            "YAAW_THREAD_ID": threadID.uuidString,
            "YAAW_EVENT_LOG": eventLogURL.path,
        ]
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        try e2eAssert(process.terminationStatus == 0, "yaaw-notify helper exited successfully")
    }
}
