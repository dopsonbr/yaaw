/// The selectable surfaces shown in the right tool panel.
public enum RightPanelMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// The file browser.
    case files
    /// The web browser preview.
    case browser
    /// The embedded `nvim` editor.
    case nvim
    /// The git surface (`lazygit`).
    case git

    /// The stable identifier for the mode (its raw value).
    public var id: String {
        rawValue
    }

    /// The human-readable label for the mode.
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

    /// The next mode when cycling forward through the panel.
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

    /// The previous mode when cycling backward through the panel.
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
