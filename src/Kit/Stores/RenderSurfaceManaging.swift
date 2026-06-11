import Foundation

/// The terminal/browser surface role a store can drive. Mirrors the pre-rewrite
/// `TerminalRole` but lives in `YAAWKit` so stores never depend on the app or the
/// Chunk D render host. The real `RenderHostClient`-backed manager (XPC + native
/// compositing) is wired in D-part-2/integration; stores only ever call this
/// protocol.
public enum RenderSurfaceRole: Equatable, Sendable, Hashable {
    /// The agent CLI surface bound to a project thread.
    case project(threadID: UUID)
    /// The bottom/global shell terminal for a thread.
    case bottom(threadID: UUID)
    /// The shared (single) nvim editor surface for a thread.
    case nvim(threadID: UUID)
    /// A per-file nvim tab surface for a thread.
    case nvimTab(threadID: UUID, tabID: String)
    /// The lazygit/git surface for a thread.
    case lazygit(threadID: UUID)
}

/// A description of how a surface should be launched. The stores hand this to the
/// `RenderSurfaceManaging` manager, which (in integration) builds the PTY/browser
/// in an isolated `YAAWRenderHost` helper. The spec calls this
/// `TerminalSessionManaging`/`RenderHostClient`; it is modeled here as the set of
/// methods the stores need to drive a surface.
public struct RenderSurfaceLaunch: Equatable, Sendable {
    public var role: RenderSurfaceRole
    public var title: String
    public var workingDirectory: URL
    public var command: [String]
    public var agentCLI: AgentCLIKind
    /// The capture-wrapped agent launch descriptor, when this is an agent PTY
    /// surface; `nil` for plain exec surfaces (bottom shell, nvim, lazygit).
    public var agentLaunchDescriptor: AgentCLITerminalLaunchDescriptor?
    /// A token whose change forces the manager to relaunch the surface (used for
    /// nvim file switches). `nil` when no relaunch is requested.
    public var relaunchToken: UUID?

    public init(
        role: RenderSurfaceRole,
        title: String,
        workingDirectory: URL,
        command: [String],
        agentCLI: AgentCLIKind,
        agentLaunchDescriptor: AgentCLITerminalLaunchDescriptor? = nil,
        relaunchToken: UUID? = nil
    ) {
        self.role = role
        self.title = title
        self.workingDirectory = workingDirectory
        self.command = command
        self.agentCLI = agentCLI
        self.agentLaunchDescriptor = agentLaunchDescriptor
        self.relaunchToken = relaunchToken
    }

    /// Whether this launch drives an agent PTY (vs. a plain exec surface).
    public var isAgentPTY: Bool { agentLaunchDescriptor != nil }
}

/// Drives terminal/browser surfaces on behalf of the stores: launch, resize,
/// shutdown. `Sendable` so it can be injected across isolation domains. The real
/// implementation (Chunk D) manages an XPC `RenderHostClient` per surface and
/// composites its frames into the pane; `NoopRenderSurfaceManager` is the default,
/// and `RecordingRenderSurfaceManager` is the test fake.
public protocol RenderSurfaceManaging: Sendable {
    /// Launches (or re-activates) the surface for `launch`, returning whether a
    /// surface is now active. Idempotent for an identical launch.
    @discardableResult
    func activate(_ launch: RenderSurfaceLaunch) -> Bool
    /// Tears down the surface for `role`, if any.
    func shutdown(role: RenderSurfaceRole)
    /// Whether a surface is currently active for `role`.
    func isActive(role: RenderSurfaceRole) -> Bool
}

/// The default no-op surface manager: stores construct and persist correctly with
/// no live rendering. Used in the bare binary and as the `AppEnvironment` default.
public final class NoopRenderSurfaceManager: RenderSurfaceManaging {
    public init() {}
    @discardableResult
    public func activate(_ launch: RenderSurfaceLaunch) -> Bool { false }
    public func shutdown(role: RenderSurfaceRole) {}
    public func isActive(role: RenderSurfaceRole) -> Bool { false }
}
