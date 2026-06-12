import Foundation

extension WorkspaceStore {
    /// CLIs whose terminal title is a trustworthy session-name source. Mirrors the
    /// manifest `usesTerminalTitleAsSessionName` capability (Chunk C); kept here so
    /// metadata application can resolve it synchronously. Codex titles are session
    /// names; Claude titles are transient tool activity.
    static let titleUsageByKind: [AgentCLIKind: Bool] = [
        .codex: true, .claude: false, .opencode: true, .copilot: true,
    ]

    var titleUsageByKind: [AgentCLIKind: Bool] { Self.titleUsageByKind }

    // MARK: - Capture-offset / descriptor accessors (used by ActivityStore polling)

    func captureReadOffsetForThread(_ threadID: UUID) -> UInt64 {
        captureReadOffsetsByThreadID[threadID] ?? 0
    }

    func setCaptureReadOffset(_ offset: UInt64, forThread threadID: UUID) {
        captureReadOffsetsByThreadID[threadID] = offset
    }

    /// The threads with a cached running launch descriptor, stable-ordered for
    /// deterministic activity polling.
    var activeProjectLaunchDescriptorThreadIDs: [UUID] {
        activeProjectLaunchDescriptorsByThreadID.keys.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - Launch descriptors

    /// Builds the surface launch for a role, or `nil` when it cannot launch
    /// (missing directory, unresolved session link). The async variant is needed
    /// because the agent-PTY path builds a descriptor via the binding actor and
    /// may auto-link before launch.
    public func surfaceLaunch(for role: RenderSurfaceRole) async -> RenderSurfaceLaunch? {
        switch role {
        case .bottom(let threadID):
            return bottomLaunch(threadID: threadID, role: role)
        case .project(let threadID):
            return await projectLaunch(threadID: threadID, role: role)
        case .nvim(let threadID):
            return nvimLaunch(threadID: threadID, role: role)
        case .nvimTab(let threadID, let tabID):
            return nvimTabLaunch(threadID: threadID, tabID: tabID, role: role)
        case .lazygit(let threadID):
            return lazygitLaunch(threadID: threadID, role: role)
        case .browser(let threadID, let tabID):
            return browserLaunch(threadID: threadID, tabID: tabID, role: role)
        }
    }

    private func bottomLaunch(threadID: UUID, role: RenderSurfaceRole) -> RenderSurfaceLaunch? {
        guard let thread = activeThread(id: threadID),
            requireExistingDirectory(thread.workingDirectory, role: role)
        else { return nil }
        return RenderSurfaceLaunch(
            role: role,
            title: "Bottom Terminal",
            workingDirectory: thread.workingDirectory,
            command: [defaultShellPath()],
            agentCLI: thread.agentCLI
        )
    }

    private func projectLaunch(threadID: UUID, role: RenderSurfaceRole) async
        -> RenderSurfaceLaunch?
    {
        guard var thread = activeThread(id: threadID) else { return nil }
        if sessionLinkRequiredThreadIDs.contains(threadID),
            !(await autoLinkUnboundThreadIfExactMatch(
                threadID: threadID, diagnosticName: "session_auto_linked_before_launch"))
        {
            recordDiagnostic(
                category: "AgentCLI",
                name: "session_link_required",
                metadata: [
                    "thread_id": threadID.uuidString,
                    "agent_cli": thread.agentCLI.rawValue,
                ]
            )
            return nil
        }
        thread = activeThread(id: threadID) ?? thread
        guard requireExistingDirectory(thread.workingDirectory, role: role) else { return nil }
        let launchDescriptor: AgentCLITerminalLaunchDescriptor
        if let active = activeProjectLaunchDescriptorsByThreadID[threadID] {
            launchDescriptor = active
        } else {
            captureReadOffsetsByThreadID.removeValue(forKey: threadID)
            activity?.invalidatePolling(threadID: threadID)
            launchDescriptor = await environment.sessionBindingActor.terminalLaunchDescriptor(
                for: thread,
                executableNameOverride: settings.configuration.agentExecutableName(
                    for: thread.agentCLI),
                permissionModes: settings.permissionModes(for: thread.agentCLI)
            )
        }
        activeProjectLaunchDescriptorsByThreadID[threadID] = launchDescriptor
        return RenderSurfaceLaunch(
            role: role,
            title: "\(thread.agentCLI.displayName) Terminal",
            workingDirectory: thread.workingDirectory,
            command: launchDescriptor.command,
            agentCLI: thread.agentCLI,
            agentLaunchDescriptor: launchDescriptor
        )
    }

    private func nvimLaunch(threadID: UUID, role: RenderSurfaceRole) -> RenderSurfaceLaunch? {
        guard let thread = activeThread(id: threadID),
            requireExistingDirectory(thread.workingDirectory, role: role)
        else { return nil }
        let arguments = rightPanel?.nvimPath(forThreadID: threadID).map { [$0] } ?? []
        return RenderSurfaceLaunch(
            role: role,
            title: "nvim",
            workingDirectory: thread.workingDirectory,
            command: externalToolCommand(
                preferredNames: settings.configuration.tools.editors.preferred, arguments: arguments
            ),
            agentCLI: thread.agentCLI,
            relaunchToken: rightPanel?.nvimRelaunchTokensByThreadID[threadID]
        )
    }

    private func nvimTabLaunch(threadID: UUID, tabID: String, role: RenderSurfaceRole)
        -> RenderSurfaceLaunch?
    {
        guard let thread = activeThread(id: threadID),
            requireExistingDirectory(thread.workingDirectory, role: role),
            let tab = rightPanel?.rightPanelStatesByThreadID[threadID]?.tabs.first(where: {
                $0.id == tabID
            }),
            tab.kind == .nvim
        else { return nil }
        let arguments = tab.relativePath.map { [$0] } ?? []
        let key = rightPanel?.nvimTabKey(threadID: threadID, tabID: tabID)
        return RenderSurfaceLaunch(
            role: role,
            title: tab.title,
            workingDirectory: thread.workingDirectory,
            command: externalToolCommand(
                preferredNames: settings.configuration.tools.editors.preferred, arguments: arguments
            ),
            agentCLI: thread.agentCLI,
            relaunchToken: key.flatMap { rightPanel?.nvimRelaunchTokensByTabKey[$0] }
        )
    }

    private func lazygitLaunch(threadID: UUID, role: RenderSurfaceRole) -> RenderSurfaceLaunch? {
        guard let thread = activeThread(id: threadID),
            requireExistingDirectory(thread.workingDirectory, role: role)
        else { return nil }
        return RenderSurfaceLaunch(
            role: role,
            title: "Git",
            workingDirectory: thread.workingDirectory,
            command: gitToolCommand(),
            agentCLI: thread.agentCLI
        )
    }

    private func browserLaunch(threadID: UUID, tabID: String, role: RenderSurfaceRole)
        -> RenderSurfaceLaunch?
    {
        guard let thread = activeThread(id: threadID),
            requireExistingDirectory(thread.workingDirectory, role: role),
            let tab = rightPanel?.rightPanelStatesByThreadID[threadID]?.tabs.first(where: {
                $0.id == tabID
            }),
            tab.kind == .browser,
            let urlString = tab.urlString, !urlString.isEmpty
        else { return nil }
        // The browser helper hosts a `WKWebView`, not an exec process: the initial
        // URL travels in `command` as `["load", urlString]` (the helper parses
        // `command.first == "load"`). Subsequent navigation goes over the input
        // channel; a URL change re-activates with a new command (relaunch),
        // mirroring the nvim file-switch model.
        return RenderSurfaceLaunch(
            role: role,
            title: tab.title,
            workingDirectory: thread.workingDirectory,
            command: ["load", urlString],
            agentCLI: thread.agentCLI
        )
    }

    // MARK: - Activation

    /// Activates (launches or re-focuses) the render surface for a role. Non-agent and
    /// already-cached agent launches activate synchronously; a first agent launch is
    /// built asynchronously. Returns whether the surface is active after the call.
    @discardableResult
    public func activateTerminal(role: RenderSurfaceRole) -> Bool {
        // Synchronous activation path: build the non-agent launch directly and the
        // agent launch only when a descriptor is already cached (the common
        // re-activation case). For the first agent launch a descriptor is built
        // asynchronously by the caller via `activateProjectTerminal(role:)`.
        let surfaceManager = environment.renderSurfaceManager
        switch role {
        case .project(let threadID):
            guard activeThread(id: threadID) != nil,
                !sessionLinkRequiredThreadIDs.contains(threadID),
                let cached = activeProjectLaunchDescriptorsByThreadID[threadID],
                let thread = activeThread(id: threadID),
                requireExistingDirectory(thread.workingDirectory, role: role)
            else {
                Task { await activateProjectTerminal(role: role) }
                return surfaceManager.isActive(role: role)
            }
            recordLaunchRequested(role: role)
            return surfaceManager.activate(
                RenderSurfaceLaunch(
                    role: role,
                    title: "\(thread.agentCLI.displayName) Terminal",
                    workingDirectory: thread.workingDirectory,
                    command: cached.command,
                    agentCLI: thread.agentCLI,
                    agentLaunchDescriptor: cached
                ))
        default:
            guard let launch = syncNonAgentLaunch(for: role) else { return false }
            recordLaunchRequested(role: role)
            return surfaceManager.activate(launch)
        }
    }

    private func activateProjectTerminal(role: RenderSurfaceRole) async {
        guard let launch = await surfaceLaunch(for: role) else { return }
        recordLaunchRequested(role: role)
        environment.renderSurfaceManager.activate(launch)
    }

    private func syncNonAgentLaunch(for role: RenderSurfaceRole) -> RenderSurfaceLaunch? {
        switch role {
        case .bottom(let threadID): return bottomLaunch(threadID: threadID, role: role)
        case .nvim(let threadID): return nvimLaunch(threadID: threadID, role: role)
        case .nvimTab(let threadID, let tabID):
            return nvimTabLaunch(threadID: threadID, tabID: tabID, role: role)
        case .lazygit(let threadID): return lazygitLaunch(threadID: threadID, role: role)
        case .browser(let threadID, let tabID):
            return browserLaunch(threadID: threadID, tabID: tabID, role: role)
        case .project: return nil
        }
    }

    private func recordLaunchRequested(role: RenderSurfaceRole) {
        recordDiagnostic(
            category: "Terminal", name: "terminal_launch_requested",
            metadata: ["role": role.diagnosticName])
    }

    /// Shuts down the render surface for a role; for project terminals it also clears the
    /// cached launch descriptor and capture offset and records the terminal as closed.
    public func terminateTerminal(role: RenderSurfaceRole) {
        environment.renderSurfaceManager.shutdown(role: role)
        if case .project(let threadID) = role {
            activeProjectLaunchDescriptorsByThreadID.removeValue(forKey: threadID)
            captureReadOffsetsByThreadID.removeValue(forKey: threadID)
            activity?.recordAgentTerminalClosed(threadID: threadID)
        }
    }

    // MARK: - Command resolution

    private func requireExistingDirectory(_ url: URL, role: RenderSurfaceRole) -> Bool {
        guard isExistingDirectory(url) else {
            recordDiagnostic(
                category: "Terminal",
                name: "terminal_launch_failed",
                metadata: [
                    "role": role.diagnosticName,
                    "reason": "missing_working_directory",
                    "path": sanitizedDiagnosticValue(url.path),
                ]
            )
            return false
        }
        return true
    }

    private func defaultShellPath() -> String {
        environment.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    func externalToolCommand(preferredNames: [String], arguments: [String] = []) -> [String] {
        for name in preferredNames {
            if let path = environment.externalToolResolver.executablePath(
                named: name, environment: environment.environment)
            {
                return [path] + arguments
            }
        }
        return [preferredNames[0]] + arguments
    }

    private func gitToolCommand() -> [String] {
        let gitTool = settings.configuration.tools.git.preferred
        if let resolved = environment.externalToolResolver.executablePath(
            named: gitTool, environment: environment.environment)
        {
            return [resolved]
        }
        let fallback = settings.configuration.tools.diff.fallback
        if isGitDiffFallback(fallback) {
            let gitExecutable = fallback.first ?? "git"
            let resolvedGit =
                environment.externalToolResolver.executablePath(
                    named: gitExecutable, environment: environment.environment) ?? gitExecutable
            return [resolvedGit, "--no-pager", "diff"]
        }
        guard let executable = fallback.first else { return ["git", "--no-pager", "diff"] }
        let resolved =
            environment.externalToolResolver.executablePath(
                named: executable, environment: environment.environment) ?? executable
        return [resolved] + Array(fallback.dropFirst())
    }

    private func isGitDiffFallback(_ command: [String]) -> Bool {
        command.count == 2
            && URL(fileURLWithPath: command[0]).lastPathComponent == "git"
            && command[1] == "diff"
    }

    private func sanitizedDiagnosticValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

extension RenderSurfaceRole {
    var diagnosticName: String {
        switch self {
        case .project: return "project"
        case .bottom: return "bottom"
        case .nvim, .nvimTab: return "nvim"
        case .lazygit: return "lazygit"
        case .browser: return "browser"
        }
    }
}
