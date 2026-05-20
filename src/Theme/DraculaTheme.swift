public enum DraculaRole: String, CaseIterable, Identifiable, Sendable {
    case background
    case currentLine
    case foreground
    case comment
    case cyan
    case green
    case orange
    case pink
    case purple
    case red
    case yellow

    public var id: String {
        rawValue
    }
}

public struct DraculaToken: Equatable, Sendable {
    public let role: DraculaRole
    public let hex: String

    public init(role: DraculaRole, hex: String) {
        self.role = role
        self.hex = hex
    }
}

public enum DraculaTheme {
    public static let tokens: [DraculaToken] = [
        DraculaToken(role: .background, hex: "#282a36"),
        DraculaToken(role: .currentLine, hex: "#44475a"),
        DraculaToken(role: .foreground, hex: "#f8f8f2"),
        DraculaToken(role: .comment, hex: "#6272a4"),
        DraculaToken(role: .cyan, hex: "#8be9fd"),
        DraculaToken(role: .green, hex: "#50fa7b"),
        DraculaToken(role: .orange, hex: "#ffb86c"),
        DraculaToken(role: .pink, hex: "#ff79c6"),
        DraculaToken(role: .purple, hex: "#bd93f9"),
        DraculaToken(role: .red, hex: "#ff5555"),
        DraculaToken(role: .yellow, hex: "#f1fa8c")
    ]

    public static func hex(for role: DraculaRole) -> String {
        tokens.first { $0.role == role }?.hex ?? "#f8f8f2"
    }
}
