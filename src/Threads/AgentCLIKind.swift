public enum AgentCLIKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case codex
    case claude

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude"
        }
    }
}
