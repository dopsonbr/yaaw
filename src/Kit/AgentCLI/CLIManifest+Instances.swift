import Foundation

extension CLIManifest {
    /// The four built-in CLI manifests, keyed by family.
    public static let builtIns: [AgentCLIKind: CLIManifest] = Dictionary(
        uniqueKeysWithValues: [codex, claude, opencode, copilot].map { ($0.kind, $0) }
    )

    /// The manifest for the given family, if one is built in.
    public static func builtIn(for kind: AgentCLIKind) -> CLIManifest? {
        builtIns[kind]
    }

    /// Codex: `codex resume <id>`; catalog in `~/.codex` (index + history);
    /// renamed interactively; title is authoritative; discoverable presets.
    public static let codex = CLIManifest(
        kind: .codex,
        executableName: "codex",
        resumeTemplate: .positional(prefix: ["resume"]),
        startNameCapability: .none,
        renameCapability: .viaStartupInput(command: "/rename {name}\n"),
        usesTerminalTitleAsSessionName: true,
        catalogLocations: [
            CatalogLocation(
                basePath: "~/.codex", pattern: "session_index.jsonl", fileFormat: .jsonl),
            CatalogLocation(basePath: "~/.codex", pattern: "history.jsonl", fileFormat: .jsonl),
        ],
        sessionIdentityKeys: ["session_id", "sessionId", "id", "conversation_id", "thread_id"],
        // `text` (history first-message) is appended last so the index's named
        // fields always win when present.
        displayNameKeys: [
            "thread_name", "session_name", "sessionName", "title", "name", "summary", "text",
        ],
        workingDirectoryKeys: [
            "cwd", "working_directory", "workingDirectory", "directory", "path",
        ],
        // `ts` (history unix timestamp) appended last for the same reason.
        timestampKeys: ["updated_at", "updatedAt", "timestamp", "created_at", "createdAt", "ts"],
        directoryMatchingStrict: false,
        outputMetadataPatterns: [
            OutputMetadataPattern(
                field: .sessionIdentity,
                prefixes: [
                    "yaaw_session_id=", "session_id=", "codex_session_id=",
                    "codex session id:", "session id:",
                ]
            ),
            OutputMetadataPattern(
                field: .displayName,
                prefixes: [
                    "yaaw_session_name=", "session_name=", "codex_session_name=",
                    "codex session name:", "session name:", "name:",
                ]
            ),
            OutputMetadataPattern(
                field: .title,
                prefixes: [
                    "yaaw_session_title=", "session_title=", "codex_session_title=",
                    "codex session title:", "session title:", "title:",
                ]
            ),
        ],
        permissionPresetSource: .discoverable
    )

    /// Claude: `claude --resume <id>` / `--name <name>`; catalog under
    /// `~/.claude/projects/{encoded-workdir}/*.jsonl`; type-dependent name rules;
    /// title NOT authoritative; rename only after resume; discoverable presets.
    public static let claude = CLIManifest(
        kind: .claude,
        executableName: "claude",
        resumeTemplate: .flagSpaced(flag: "--resume"),
        startNameCapability: .viaFlag(flag: "--name"),
        renameCapability: .viaStartupInputIfResumed(command: "/rename {name}\n"),
        usesTerminalTitleAsSessionName: false,
        catalogLocations: [
            CatalogLocation(
                basePath: "~/.claude/projects",
                pattern: "{encoded-workdir}/*.jsonl",
                fileFormat: .jsonl
            )
        ],
        sessionIdentityKeys: ["sessionId", "session_id", "id", "uuid"],
        displayNameKeys: ["customTitle", "agentName", "summary"],
        workingDirectoryKeys: ["cwd", "working_directory", "workingDirectory", "directory"],
        timestampKeys: ["timestamp", "updated_at", "updatedAt", "created_at", "createdAt"],
        catalogMetadataRules: CatalogMetadataRules(
            typeKey: "type",
            typeDependentFields: [
                TypeDependentField(whenType: "custom-title", field: "customTitle", precedence: 0),
                TypeDependentField(whenType: "agent-name", field: "agentName", precedence: 1),
                TypeDependentField(whenType: "summary", field: "summary", precedence: 2),
            ]
        ),
        directoryMatchingStrict: false,
        outputMetadataPatterns: [
            OutputMetadataPattern(
                field: .sessionIdentity,
                prefixes: [
                    "yaaw_session_id=", "session_id=", "claude_session_id=",
                    "claude session id:", "session id:",
                ]
            ),
            OutputMetadataPattern(
                field: .displayName,
                prefixes: [
                    "yaaw_session_name=", "session_name=", "claude_session_name=",
                    "claude session name:", "session name:", "name:",
                ]
            ),
            OutputMetadataPattern(
                field: .title,
                prefixes: [
                    "yaaw_session_title=", "session_title=", "claude_session_title=",
                    "claude session title:", "session title:", "title:",
                ]
            ),
        ],
        permissionPresetSource: .discoverable
    )

    /// OpenCode: `opencode --session <id>`; one JSON file per session under
    /// `~/.local/share/opencode/storage/session`; strict directory matching;
    /// no start-name / rename; no permission presets.
    public static let opencode = CLIManifest(
        kind: .opencode,
        executableName: "opencode",
        resumeTemplate: .flagSpaced(flag: "--session"),
        startNameCapability: .none,
        renameCapability: .none,
        usesTerminalTitleAsSessionName: true,
        catalogLocations: [
            CatalogLocation(
                basePath: "~/.local/share/opencode/storage/session",
                pattern: "*.json",
                fileFormat: .json
            )
        ],
        sessionIdentityKeys: ["id", "sessionID", "sessionId", "session_id"],
        displayNameKeys: ["title", "name", "summary", "description"],
        workingDirectoryKeys: [
            "directory", "cwd", "working_directory", "workingDirectory", "path",
        ],
        timestampKeys: ["updated", "updated_at", "updatedAt", "time", "created_at"],
        directoryMatchingStrict: true,
        outputMetadataPatterns: [
            OutputMetadataPattern(
                field: .sessionIdentity,
                prefixes: [
                    "yaaw_session_id=", "session_id=", "opencode_session_id=",
                    "opencode session id:", "session id:",
                ]
            ),
            OutputMetadataPattern(
                field: .displayName,
                prefixes: [
                    "yaaw_session_name=", "session_name=", "opencode_session_name=",
                    "opencode session name:", "session name:", "name:",
                ]
            ),
            OutputMetadataPattern(
                field: .title,
                prefixes: [
                    "yaaw_session_title=", "session_title=", "opencode_session_title=",
                    "opencode session title:", "session title:", "title:",
                ]
            ),
        ],
        permissionPresetSource: .none
    )

    /// Copilot: `copilot --resume=<id>` / `--name <name>`; per-session metadata +
    /// events under `~/.copilot/session-state`; strict directory matching; rename
    /// only after resume; discoverable presets.
    public static let copilot = CLIManifest(
        kind: .copilot,
        executableName: "copilot",
        resumeTemplate: .flagEquals(flag: "--resume"),
        startNameCapability: .viaFlag(flag: "--name"),
        renameCapability: .viaStartupInputIfResumed(command: "/rename {name}\n"),
        usesTerminalTitleAsSessionName: true,
        catalogLocations: [
            CatalogLocation(
                basePath: "~/.copilot/session-state",
                pattern: "*/vscode.metadata.json",
                fileFormat: .json
            ),
            CatalogLocation(
                basePath: "~/.copilot/session-state",
                pattern: "*/events.jsonl",
                fileFormat: .jsonl
            ),
        ],
        sessionIdentityKeys: ["session_id", "sessionId", "id"],
        displayNameKeys: [
            "name", "title", "sessionName", "session_name", "firstUserMessage",
            "first_user_message",
        ],
        workingDirectoryKeys: [
            "cwd", "directory", "working_directory", "workingDirectory", "path",
        ],
        timestampKeys: ["updated_at", "updatedAt", "timestamp", "created_at", "createdAt", "time"],
        directoryMatchingStrict: true,
        outputMetadataPatterns: [
            OutputMetadataPattern(
                field: .sessionIdentity,
                prefixes: [
                    "yaaw_session_id=", "session_id=", "copilot_session_id=",
                    "copilot session id:", "session id:",
                ]
            ),
            OutputMetadataPattern(
                field: .displayName,
                prefixes: [
                    "yaaw_session_name=", "session_name=", "copilot_session_name=",
                    "copilot session name:", "session name:", "name:",
                ]
            ),
            OutputMetadataPattern(
                field: .title,
                prefixes: [
                    "yaaw_session_title=", "session_title=", "copilot_session_title=",
                    "copilot session title:", "session title:", "title:",
                ]
            ),
        ],
        permissionPresetSource: .discoverable
    )
}
