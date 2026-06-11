import Foundation

public enum AgentCLIKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case codex
    case claude
    case opencode
    case copilot

    public var id: String {
        rawValue
    }

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

    public var brandIconResourceName: String {
        "agent-\(rawValue)"
    }

    public var brandIconResourceExtensions: [String] {
        switch self {
        case .codex, .claude, .opencode, .copilot:
            ["png", "svg"]
        }
    }

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
