import Foundation

extension SessionBindingActor {
    /// A capture-wrapped terminal launch plan: the agent command embedded in an
    /// interactive shell that traps signals, reports a non-zero exit, then drops
    /// to a login shell so the terminal stays open. Capture and activity log
    /// paths plus environment are populated, and the notify helper installed.
    public func terminalLaunchDescriptor(
        for thread: AgentThread,
        executableNameOverride: String? = nil,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> AgentCLITerminalLaunchDescriptor {
        let command = invocation(
            for: thread,
            executableNameOverride: executableNameOverride,
            permissionModes: permissionModes
        ).command
        let helperBinURL = installNotifyHelperIfNeeded()
        let activityLogURL = activityLogURL(for: thread)
        let captureLogURL = captureLogURL(for: thread)
        if let captureLogURL {
            try? FileManager.default.createDirectory(
                at: captureLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: captureLogURL)
        }
        let shellPath = interactiveShellPath()
        let agentCommand = command.map(Self.shellQuoted).joined(separator: " ")
        let launchEnvironment = shellEnvironment(
            thread: thread,
            helperBinURL: helperBinURL,
            activityLogURL: activityLogURL
        )
        let shellCommand =
            "trap 'exit 143' TERM; trap 'exit 129' HUP; \(agentCommand); "
            + "yaaw_exit_status=$?; if [ \"$yaaw_exit_status\" -ne 0 ]; then "
            + "printf '\\nYAAW: agent command exited with status %s\\n' \"$yaaw_exit_status\"; fi; "
            + "exec \(Self.shellQuoted(shellPath)) -l"
        return AgentCLITerminalLaunchDescriptor(
            command: [shellPath, "-lic", shellCommand],
            environment: launchEnvironment,
            captureLogURL: captureLogURL,
            startupInput: startupInput(for: thread)
        )
    }

    func startupInput(for thread: AgentThread) -> String? {
        guard let pendingSessionRename = thread.pendingSessionRename,
            let manifest = manifestsByKind[thread.agentCLI]
        else { return nil }
        return manifest.startupInput(
            forPendingRename: pendingSessionRename,
            sessionIdentity: thread.sessionIdentity
        )
    }

    private func shellEnvironment(
        thread: AgentThread,
        helperBinURL: URL?,
        activityLogURL: URL?
    ) -> [String: String] {
        var launchEnvironment = environment
        launchEnvironment["YAAW_THREAD_ID"] = thread.id.uuidString
        launchEnvironment["YAAW_PROJECT_ID"] = thread.projectID.uuidString
        if let activityLogURL {
            try? FileManager.default.createDirectory(
                at: activityLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            launchEnvironment["YAAW_EVENT_LOG"] = activityLogURL.path
        }
        if let helperBinURL {
            let path = launchEnvironment["PATH"] ?? ""
            launchEnvironment["PATH"] =
                path.isEmpty ? helperBinURL.path : "\(helperBinURL.path):\(path)"
        }
        if launchEnvironment["TERM"]?.agentCLINilIfBlank == nil {
            launchEnvironment["TERM"] = "xterm-256color"
        }
        if launchEnvironment["COLORTERM"]?.agentCLINilIfBlank == nil {
            launchEnvironment["COLORTERM"] = "truecolor"
        }
        launchEnvironment["TERM_PROGRAM"] = "YAAW"
        return launchEnvironment
    }

    @discardableResult
    func installNotifyHelperIfNeeded() -> URL? {
        let helperBinURL = helperBinDirectory
        let helperURL = helperBinURL.appendingPathComponent("yaaw-notify")
        do {
            try FileManager.default.createDirectory(
                at: helperBinURL, withIntermediateDirectories: true)
            try Self.notifyHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
            return helperBinURL
        } catch {
            return nil
        }
    }

    private func interactiveShellPath() -> String {
        if let shell = environment["SHELL"],
            FileManager.default.isExecutableFile(atPath: shell)
        {
            return shell
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        }
        return "/bin/bash"
    }

    static func shellQuoted(_ argument: String) -> String {
        if argument.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.union(
                .init(charactersIn: "\"'\\$`;&|<>[]{}()!#*?~"))) == nil
        {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let notifyHelperScript = """
        #!/bin/zsh
        set -e

        activity_status=""
        title=""
        body=""

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --status)
              activity_status="$2"
              shift 2
              ;;
            --title)
              title="$2"
              shift 2
              ;;
            --body)
              body="$2"
              shift 2
              ;;
            *)
              if [[ -z "$body" ]]; then
                body="$1"
              else
                body="$body $1"
              fi
              shift
              ;;
          esac
        done

        case "$activity_status" in
          needs-input|needs_input) activity_status="needsInput" ;;
          working|complete|inactive) ;;
          "") activity_status="" ;;
          *) activity_status="" ;;
        esac

        json_escape() {
          local s="$1"
          s="${s//\\/\\\\}"
          s="${s//\\"/\\\\\\"}"
          s="${s//$'\\n'/\\\\n}"
          s="${s//$'\\r'/\\\\r}"
          s="${s//$'\\t'/\\\\t}"
          print -r -- "$s"
        }

        if [[ -n "$YAAW_EVENT_LOG" && -n "$YAAW_THREAD_ID" ]]; then
          mkdir -p "$(dirname "$YAAW_EVENT_LOG")"
          printf '{"thread_id":"%s","status":"%s","title":"%s","body":"%s","source":"helper","created_at":%s}\\n' \\
            "$(json_escape "$YAAW_THREAD_ID")" \\
            "$(json_escape "$activity_status")" \\
            "$(json_escape "$title")" \\
            "$(json_escape "$body")" \\
            "$(date +%s)" >> "$YAAW_EVENT_LOG"
        fi

        notification_title="${title:-YAAW}"
        notification_body="${body:-$activity_status}"
        printf '\\033]777;notify;%s;%s\\007' "$notification_title" "$notification_body"
        """
}
