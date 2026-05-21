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

    public func imagePasteText(for imageURL: URL) -> String {
        "Attached image: \(imageURL.path)"
    }
}
