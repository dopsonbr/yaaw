public enum RightPanelMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case files
    case nvim
    case git

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .files:
            "Files"
        case .nvim:
            "nvim"
        case .git:
            "Git"
        }
    }

    public var next: RightPanelMode {
        switch self {
        case .files:
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
        case .git:
            .files
        case .nvim:
            .git
        }
    }
}
