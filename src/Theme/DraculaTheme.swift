public enum ThemeRole: String, CaseIterable, Identifiable, Sendable {
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

public typealias DraculaRole = ThemeRole

public enum ThemeGroup: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case highContrast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .highContrast:
            "High Contrast"
        }
    }
}

public struct ThemeToken: Equatable, Sendable {
    public let role: ThemeRole
    public let hex: String

    public init(role: ThemeRole, hex: String) {
        self.role = role
        self.hex = hex
    }
}

public struct DraculaToken: Equatable, Sendable {
    public let role: ThemeRole
    public let hex: String

    public init(role: ThemeRole, hex: String) {
        self.role = role
        self.hex = hex
    }
}

public struct ThemeDefinition: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let group: ThemeGroup
    public let tokens: [ThemeToken]

    public init(id: String, displayName: String, group: ThemeGroup, tokens: [ThemeToken]) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.tokens = tokens
    }

    public func hex(for role: ThemeRole) -> String {
        tokens.first { $0.role == role }?.hex ?? ThemeCatalog.defaultTheme.hex(for: role)
    }
}

public enum ThemeCatalog {
    public static let defaultID = "dracula"

    public static let themes: [ThemeDefinition] = [
        theme(
            id: "light-2026",
            displayName: "Light 2026",
            group: .light,
            background: "#f8f8f2",
            currentLine: "#e8e8e3",
            foreground: "#282a36",
            comment: "#6b7280",
            cyan: "#007acc",
            green: "#16825d",
            orange: "#b85c00",
            pink: "#b71f78",
            purple: "#6f42c1",
            red: "#d12f2f",
            yellow: "#8a6f00"
        ),
        theme(
            id: "light-modern",
            displayName: "Light Modern",
            group: .light,
            background: "#ffffff",
            currentLine: "#f0f3f6",
            foreground: "#1f2328",
            comment: "#6e7781",
            cyan: "#0969da",
            green: "#1a7f37",
            orange: "#bc4c00",
            pink: "#bf3989",
            purple: "#8250df",
            red: "#cf222e",
            yellow: "#9a6700"
        ),
        theme(
            id: "light-plus",
            displayName: "Light+",
            group: .light,
            background: "#ffffff",
            currentLine: "#eeeeee",
            foreground: "#333333",
            comment: "#767676",
            cyan: "#267f99",
            green: "#008000",
            orange: "#af00db",
            pink: "#c586c0",
            purple: "#0000ff",
            red: "#a31515",
            yellow: "#795e26"
        ),
        theme(
            id: "quiet-light",
            displayName: "Quiet Light",
            group: .light,
            background: "#f5f5f5",
            currentLine: "#e8e8e8",
            foreground: "#333333",
            comment: "#8c8c8c",
            cyan: "#4b83a6",
            green: "#448c27",
            orange: "#c18401",
            pink: "#b35f8b",
            purple: "#7a5fb4",
            red: "#aa3731",
            yellow: "#9c7a00"
        ),
        theme(
            id: "solarized-light",
            displayName: "Solarized Light",
            group: .light,
            background: "#fdf6e3",
            currentLine: "#eee8d5",
            foreground: "#657b83",
            comment: "#93a1a1",
            cyan: "#2aa198",
            green: "#859900",
            orange: "#cb4b16",
            pink: "#d33682",
            purple: "#6c71c4",
            red: "#dc322f",
            yellow: "#b58900"
        ),
        theme(
            id: "dracula",
            displayName: "Dracula",
            group: .dark,
            background: "#282a36",
            currentLine: "#44475a",
            foreground: "#f8f8f2",
            comment: "#6272a4",
            cyan: "#8be9fd",
            green: "#50fa7b",
            orange: "#ffb86c",
            pink: "#ff79c6",
            purple: "#bd93f9",
            red: "#ff5555",
            yellow: "#f1fa8c"
        ),
        theme(
            id: "dark-2026",
            displayName: "Dark 2026",
            group: .dark,
            background: "#1f1f1f",
            currentLine: "#2b2f30",
            foreground: "#cccccc",
            comment: "#9d9d9d",
            cyan: "#4ec9b0",
            green: "#6a9955",
            orange: "#ce9178",
            pink: "#c586c0",
            purple: "#b5cea8",
            red: "#f44747",
            yellow: "#dcdcaa"
        ),
        theme(
            id: "dark-plus",
            displayName: "Dark+",
            group: .dark,
            background: "#1e1e1e",
            currentLine: "#094771",
            foreground: "#d4d4d4",
            comment: "#6a9955",
            cyan: "#4ec9b0",
            green: "#608b4e",
            orange: "#ce9178",
            pink: "#c586c0",
            purple: "#569cd6",
            red: "#f44747",
            yellow: "#dcdcaa"
        ),
        theme(
            id: "dark-modern",
            displayName: "Dark Modern",
            group: .dark,
            background: "#181818",
            currentLine: "#2a2d2e",
            foreground: "#cccccc",
            comment: "#858585",
            cyan: "#4fc1ff",
            green: "#89d185",
            orange: "#cca700",
            pink: "#d670d6",
            purple: "#b180d7",
            red: "#f14c4c",
            yellow: "#dcdcaa"
        ),
        theme(
            id: "monokai",
            displayName: "Monokai",
            group: .dark,
            background: "#272822",
            currentLine: "#3e3d32",
            foreground: "#f8f8f2",
            comment: "#75715e",
            cyan: "#66d9ef",
            green: "#a6e22e",
            orange: "#fd971f",
            pink: "#f92672",
            purple: "#ae81ff",
            red: "#f92672",
            yellow: "#e6db74"
        ),
        theme(
            id: "solarized-dark",
            displayName: "Solarized Dark",
            group: .dark,
            background: "#002b36",
            currentLine: "#073642",
            foreground: "#839496",
            comment: "#586e75",
            cyan: "#2aa198",
            green: "#859900",
            orange: "#cb4b16",
            pink: "#d33682",
            purple: "#6c71c4",
            red: "#dc322f",
            yellow: "#b58900"
        ),
        theme(
            id: "dark-high-contrast",
            displayName: "Dark High Contrast",
            group: .highContrast,
            background: "#000000",
            currentLine: "#1f1f1f",
            foreground: "#ffffff",
            comment: "#c8c8c8",
            cyan: "#00ffff",
            green: "#00ff00",
            orange: "#ffb000",
            pink: "#ff66ff",
            purple: "#a78bfa",
            red: "#ff4d4d",
            yellow: "#ffff00"
        ),
        theme(
            id: "light-high-contrast",
            displayName: "Light High Contrast",
            group: .highContrast,
            background: "#ffffff",
            currentLine: "#e5e5e5",
            foreground: "#000000",
            comment: "#3f3f46",
            cyan: "#005cc5",
            green: "#116329",
            orange: "#953800",
            pink: "#b31d8f",
            purple: "#5319e7",
            red: "#b31d28",
            yellow: "#7d4e00"
        )
    ]

    public static let defaultTheme = themes.first { $0.id == defaultID }!

    public static var supportedIDs: [String] {
        themes.map(\.id)
    }

    public static func theme(id: String) -> ThemeDefinition? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return themes.first { $0.id == normalizedID }
    }

    public static func themes(in group: ThemeGroup) -> [ThemeDefinition] {
        themes.filter { $0.group == group }
    }

    private static func theme(
        id: String,
        displayName: String,
        group: ThemeGroup,
        background: String,
        currentLine: String,
        foreground: String,
        comment: String,
        cyan: String,
        green: String,
        orange: String,
        pink: String,
        purple: String,
        red: String,
        yellow: String
    ) -> ThemeDefinition {
        ThemeDefinition(
            id: id,
            displayName: displayName,
            group: group,
            tokens: [
                ThemeToken(role: .background, hex: background),
                ThemeToken(role: .currentLine, hex: currentLine),
                ThemeToken(role: .foreground, hex: foreground),
                ThemeToken(role: .comment, hex: comment),
                ThemeToken(role: .cyan, hex: cyan),
                ThemeToken(role: .green, hex: green),
                ThemeToken(role: .orange, hex: orange),
                ThemeToken(role: .pink, hex: pink),
                ThemeToken(role: .purple, hex: purple),
                ThemeToken(role: .red, hex: red),
                ThemeToken(role: .yellow, hex: yellow)
            ]
        )
    }
}

public enum DraculaTheme {
    public static let tokens: [DraculaToken] = ThemeCatalog.defaultTheme.tokens.map {
        DraculaToken(role: $0.role, hex: $0.hex)
    }

    public static func hex(for role: ThemeRole) -> String {
        ThemeCatalog.defaultTheme.hex(for: role)
    }
}
