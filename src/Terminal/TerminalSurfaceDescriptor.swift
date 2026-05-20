import Foundation

public enum TerminalSurfaceKind: String, Equatable, Sendable {
    case project
    case global
    case nvim
    case lazygit
}

public struct TerminalSurfaceDescriptor: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: TerminalSurfaceKind
    public var title: String
    public var placeholderText: String

    public init(
        id: UUID = UUID(),
        kind: TerminalSurfaceKind,
        title: String,
        placeholderText: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.placeholderText = placeholderText
    }
}
