import Foundation

/// The family of agent CLI a thread is bound to. Each thread launches and
/// resumes exactly one of these CLIs.
public enum AgentCLIKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    /// The OpenAI `codex` CLI.
    case codex
    /// The Anthropic `claude` CLI.
    case claude
    /// The `opencode` CLI.
    case opencode
    /// The `copilot` CLI.
    case copilot

    /// The stable identifier (the raw value) used for `Identifiable` conformance.
    public var id: String {
        rawValue
    }

    /// The human-readable name shown in the UI.
    public var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude"
        case .opencode:
            "OpenCode"
        case .copilot:
            "Copilot"
        }
    }

    /// The bundled brand-icon resource name (e.g. `agent-codex`).
    public var brandIconResourceName: String {
        "agent-\(rawValue)"
    }

    /// The file extensions to try when loading the bundled brand icon, in order.
    public var brandIconResourceExtensions: [String] {
        switch self {
        case .codex, .claude, .opencode, .copilot:
            ["png", "svg"]
        }
    }

    /// The SF Symbol name used as a fallback when the brand icon is unavailable.
    public var fallbackSystemSymbolName: String {
        switch self {
        case .codex:
            "sparkles"
        case .claude:
            "sun.max"
        case .opencode:
            "chevron.left.forwardslash.chevron.right"
        case .copilot:
            "person.2.wave.2"
        }
    }
}
