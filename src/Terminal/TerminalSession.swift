import Foundation

public enum TerminalRole: Hashable, Sendable {
    case project(threadID: UUID)
    case bottom(threadID: UUID)
    case nvim(threadID: UUID)
    case nvimTab(threadID: UUID, tabID: String)
    case lazygit(threadID: UUID)

    public var surfaceKind: TerminalSurfaceKind {
        switch self {
        case .project:
            return .project
        case .bottom:
            return .bottom
        case .nvim, .nvimTab:
            return .nvim
        case .lazygit:
            return .lazygit
        }
    }
}

public struct TerminalLaunchRequest: Equatable, Sendable {
    public var role: TerminalRole
    public var title: String
    public var workingDirectory: URL
    public var command: [String]
    public var relaunchToken: UUID?
    public var agentCLI: AgentCLIKind?

    public init(
        role: TerminalRole,
        title: String,
        workingDirectory: URL,
        command: [String],
        relaunchToken: UUID? = nil,
        agentCLI: AgentCLIKind? = nil
    ) {
        self.role = role
        self.title = title
        self.workingDirectory = workingDirectory
        self.command = command
        self.relaunchToken = relaunchToken
        self.agentCLI = agentCLI
    }
}

public enum TerminalSessionState: Equatable, Sendable {
    case active
    case terminated
    case launchFailed(String)
}

public struct TerminalSessionRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var request: TerminalLaunchRequest
    public var state: TerminalSessionState

    public init(
        id: UUID = UUID(),
        request: TerminalLaunchRequest,
        state: TerminalSessionState = .active
    ) {
        self.id = id
        self.request = request
        self.state = state
    }
}

public enum TerminalLifecycleEvent: Equatable, Sendable {
    case created(TerminalSessionRecord)
    case activated(TerminalSessionRecord)
    case terminated(TerminalSessionRecord)
    case surfaceLaunchFailed(TerminalLaunchRequest, String)
}

public protocol TerminalSessionManaging: AnyObject {
    var lifecycleEvents: [TerminalLifecycleEvent] { get }

    @discardableResult
    func activate(_ request: TerminalLaunchRequest) -> TerminalSessionRecord
    func terminate(role: TerminalRole)
    func session(for role: TerminalRole) -> TerminalSessionRecord?
}

public final class PlaceholderTerminalSessionManager: TerminalSessionManaging {
    public private(set) var lifecycleEvents: [TerminalLifecycleEvent] = []
    private var sessionsByRole: [TerminalRole: TerminalSessionRecord] = [:]

    public init() {}

    @discardableResult
    public func activate(_ request: TerminalLaunchRequest) -> TerminalSessionRecord {
        if let existing = sessionsByRole[request.role], existing.state == .active {
            if existing.request == request {
                lifecycleEvents.append(.activated(existing))
                return existing
            }
            var terminatedSession = existing
            terminatedSession.state = .terminated
            sessionsByRole[request.role] = terminatedSession
            lifecycleEvents.append(.terminated(terminatedSession))
        }

        let session = TerminalSessionRecord(request: request)
        sessionsByRole[request.role] = session
        lifecycleEvents.append(.created(session))
        lifecycleEvents.append(.activated(session))
        return session
    }

    public func terminate(role: TerminalRole) {
        guard var session = sessionsByRole[role] else { return }
        session.state = .terminated
        sessionsByRole[role] = session
        lifecycleEvents.append(.terminated(session))
    }

    public func session(for role: TerminalRole) -> TerminalSessionRecord? {
        sessionsByRole[role]
    }

    public func recordLaunchFailure(_ request: TerminalLaunchRequest, message: String) {
        let session = TerminalSessionRecord(request: request, state: .launchFailed(message))
        sessionsByRole[request.role] = session
        lifecycleEvents.append(.surfaceLaunchFailed(request, message))
    }
}
