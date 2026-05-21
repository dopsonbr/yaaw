public enum RightPanelMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case files
    case browser
    case nvim
    case git

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .files:
            "Files"
        case .browser:
            "Browser"
        case .nvim:
            "nvim"
        case .git:
            "Git"
        }
    }

    public var next: RightPanelMode {
        switch self {
        case .files:
            .browser
        case .browser:
            .git
        case .git:
            .nvim
        case .nvim:
            .files
        }
    }

    public var previous: RightPanelMode {
        switch self {
        case .files:
            .nvim
        case .browser:
            .files
        case .git:
            .browser
        case .nvim:
            .git
        }
    }
}
