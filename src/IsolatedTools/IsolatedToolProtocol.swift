import Foundation

public enum IsolatedToolKind: String, Codable, Equatable, Sendable {
    case browser
}

public enum IsolatedToolRuntimePhase: String, Codable, Equatable, Sendable {
    case idle
    case launching
    case ready
    case loading
    case failed
    case crashed
    case exited
}

public struct IsolatedToolEnvelope: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public var protocolVersion: Int
    public var toolKind: IsolatedToolKind
    public var instanceID: String
    public var messageID: String
    public var type: String
    public var payload: [String: String]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        toolKind: IsolatedToolKind,
        instanceID: String,
        messageID: String = UUID().uuidString,
        type: String,
        payload: [String: String] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.toolKind = toolKind
        self.instanceID = instanceID
        self.messageID = messageID
        self.type = type
        self.payload = payload
    }

    public func validated() throws -> Self {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw IsolatedToolProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard !instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IsolatedToolProtocolError.emptyInstanceID
        }
        guard !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IsolatedToolProtocolError.emptyMessageType
        }
        return self
    }
}

public enum IsolatedToolProtocolError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case emptyInstanceID
    case emptyMessageType
}

public struct IsolatedToolRuntimeSnapshot: Equatable, Sendable {
    public var phase: IsolatedToolRuntimePhase
    public var title: String
    public var urlString: String?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var errorMessage: String?

    public init(
        phase: IsolatedToolRuntimePhase = .idle,
        title: String = "",
        urlString: String? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.title = title
        self.urlString = urlString
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.errorMessage = errorMessage
    }
}

public enum IsolatedToolRuntimeAction: Equatable, Sendable {
    case launch
    case ready
    case stateChanged([String: String])
    case titleChanged(String)
    case error(String)
    case exited
    case crashed(String)
}

public enum IsolatedToolRuntimeReducer {
    public static func reduce(
        _ snapshot: IsolatedToolRuntimeSnapshot,
        action: IsolatedToolRuntimeAction
    ) -> IsolatedToolRuntimeSnapshot {
        var next = snapshot
        switch action {
        case .launch:
            next.phase = .launching
            next.errorMessage = nil
        case .ready:
            next.phase = .ready
            next.errorMessage = nil
        case .stateChanged(let payload):
            if let title = payload["title"] {
                next.title = title
            }
            if let urlString = payload["urlString"] {
                next.urlString = urlString.isEmpty ? nil : urlString
            }
            if let isLoading = payload["isLoading"].flatMap(Bool.init) {
                next.isLoading = isLoading
                next.phase = isLoading ? .loading : .ready
            }
            if let canGoBack = payload["canGoBack"].flatMap(Bool.init) {
                next.canGoBack = canGoBack
            }
            if let canGoForward = payload["canGoForward"].flatMap(Bool.init) {
                next.canGoForward = canGoForward
            }
            next.errorMessage = nil
        case .titleChanged(let title):
            next.title = title
        case .error(let message):
            next.phase = .failed
            next.isLoading = false
            next.errorMessage = message
        case .exited:
            next.phase = .exited
            next.isLoading = false
        case .crashed(let message):
            next.phase = .crashed
            next.isLoading = false
            next.errorMessage = message
        }
        return next
    }
}
