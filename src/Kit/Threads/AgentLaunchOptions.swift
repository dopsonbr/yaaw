import Foundation

public struct AgentLaunchOptions: Codable, Equatable, Sendable {
    public static let defaultPermissionModeID = "default"

    public var executableName: String?
    public var permissionModeID: String?
    public var additionalArguments: [String]

    public init(
        executableName: String? = nil,
        permissionModeID: String? = nil,
        additionalArguments: [String] = []
    ) {
        self.executableName = executableName?.launchOptionNilIfBlank
        self.permissionModeID = permissionModeID?.launchOptionNilIfBlank
        self.additionalArguments = additionalArguments.map(\.trimmedForLaunchOption).filter {
            !$0.isEmpty
        }
    }

    public var isEmpty: Bool {
        executableName == nil && permissionModeID == nil && additionalArguments.isEmpty
    }

    public func validated(
        for agentCLI: AgentCLIKind,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> AgentLaunchOptions {
        let modeID = permissionModeID.flatMap { id in
            guard let permissionModes else { return id }
            let supportedModeIDs = Set(permissionModes.map(\.id))
            return supportedModeIDs.isEmpty || supportedModeIDs.contains(id) ? id : nil
        }
        return AgentLaunchOptions(
            executableName: executableName,
            permissionModeID: modeID,
            additionalArguments: additionalArguments
        )
    }

    public func permissionArguments(
        for agentCLI: AgentCLIKind,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> [String] {
        guard let permissionModeID else { return [] }
        let supportedModes = permissionModes ?? AgentPermissionMode.supportedModes(for: agentCLI)
        return
            supportedModes
            .first { $0.id == permissionModeID }?
            .arguments ?? []
    }

    public static func parseAdditionalArguments(_ text: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false
        var hasCurrentArgument = false

        for character in text {
            if isEscaped {
                current.append(character)
                hasCurrentArgument = true
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                hasCurrentArgument = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasCurrentArgument = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasCurrentArgument = true
                continue
            }
            if character.isWhitespace {
                if hasCurrentArgument {
                    arguments.append(current)
                    current.removeAll(keepingCapacity: true)
                    hasCurrentArgument = false
                }
                continue
            }
            current.append(character)
            hasCurrentArgument = true
        }

        if isEscaped {
            throw AgentLaunchOptionsArgumentError.trailingEscape
        }
        if quote != nil {
            throw AgentLaunchOptionsArgumentError.unclosedQuote
        }
        if hasCurrentArgument {
            arguments.append(current)
        }
        return arguments
    }

    public static func formatAdditionalArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            let needsQuoting = argument.isEmpty || argument.contains { $0.isWhitespace }
            guard needsQuoting else { return argument }
            return
                "\"\(argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        .joined(separator: " ")
    }
}

public enum AgentLaunchOptionsArgumentError: Error, Equatable, Sendable {
    case trailingEscape
    case unclosedQuote
}

public struct AgentPermissionMode: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var arguments: [String]

    public init(id: String, displayName: String, arguments: [String]) {
        self.id = id
        self.displayName = displayName
        self.arguments = arguments
    }

    public static func supportedModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode] {
        builtInModes(for: agentCLI)
    }

    public static func builtInModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode] {
        switch agentCLI {
        case .codex:
            [
                AgentPermissionMode(
                    id: "codex-on-request",
                    displayName: "On request",
                    arguments: ["--ask-for-approval", "on-request"]
                ),
                AgentPermissionMode(
                    id: "codex-never",
                    displayName: "Never ask",
                    arguments: ["--ask-for-approval", "never"]
                ),
                AgentPermissionMode(
                    id: "codex-on-failure",
                    displayName: "On failure",
                    arguments: ["--ask-for-approval", "on-failure"]
                ),
                AgentPermissionMode(
                    id: "codex-untrusted",
                    displayName: "Untrusted",
                    arguments: ["--ask-for-approval", "untrusted"]
                ),
                AgentPermissionMode(
                    id: "codex-read-only",
                    displayName: "Read only",
                    arguments: ["--sandbox", "read-only"]
                ),
                AgentPermissionMode(
                    id: "codex-workspace-write",
                    displayName: "Workspace write",
                    arguments: ["--sandbox", "workspace-write"]
                ),
                AgentPermissionMode(
                    id: "codex-full-access",
                    displayName: "Full access",
                    arguments: ["--sandbox", "danger-full-access"]
                ),
                AgentPermissionMode(
                    id: "codex-bypass",
                    displayName: "Bypass",
                    arguments: ["--dangerously-bypass-approvals-and-sandbox"]
                ),
            ]
        case .claude:
            [
                AgentPermissionMode(
                    id: "claude-plan",
                    displayName: "Plan",
                    arguments: ["--permission-mode", "plan"]
                ),
                AgentPermissionMode(
                    id: "claude-auto",
                    displayName: "Auto",
                    arguments: ["--permission-mode", "auto"]
                ),
                AgentPermissionMode(
                    id: "claude-accept-edits",
                    displayName: "Accept edits",
                    arguments: ["--permission-mode", "acceptEdits"]
                ),
                AgentPermissionMode(
                    id: "claude-dont-ask",
                    displayName: "Don't ask",
                    arguments: ["--permission-mode", "dontAsk"]
                ),
                AgentPermissionMode(
                    id: "claude-bypass-permissions",
                    displayName: "Bypass",
                    arguments: ["--permission-mode", "bypassPermissions"]
                ),
            ]
        case .opencode:
            []
        case .copilot:
            [
                AgentPermissionMode(
                    id: "copilot-plan",
                    displayName: "Plan",
                    arguments: ["--plan"]
                ),
                AgentPermissionMode(
                    id: "copilot-autopilot",
                    displayName: "Autopilot",
                    arguments: ["--autopilot"]
                ),
                AgentPermissionMode(
                    id: "copilot-allow-all-tools",
                    displayName: "Allow tools",
                    arguments: ["--allow-all-tools"]
                ),
                AgentPermissionMode(
                    id: "copilot-allow-all",
                    displayName: "Allow all",
                    arguments: ["--allow-all"]
                ),
                AgentPermissionMode(
                    id: "copilot-yolo",
                    displayName: "YOLO",
                    arguments: ["--yolo"]
                ),
            ]
        }
    }
}

extension String {
    fileprivate var trimmedForLaunchOption: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var launchOptionNilIfBlank: String? {
        let value = trimmedForLaunchOption
        return value.isEmpty ? nil : value
    }
}
