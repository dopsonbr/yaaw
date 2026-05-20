import Combine
import Foundation

public final class AppModel: ObservableObject {
    @Published public private(set) var projects: [Project]
    @Published public private(set) var threads: [AgentThread]
    @Published public private(set) var selectedRightPanelMode: RightPanelMode
    @Published public private(set) var isGlobalTerminalExpanded: Bool

    public let projectTerminal: TerminalSurfaceDescriptor

    public init(store: InMemoryAgentIDEStore = .helloWorld()) {
        let snapshot = store.load()
        self.projects = snapshot.projects
        self.threads = snapshot.threads
        self.selectedRightPanelMode = snapshot.selectedRightPanelMode
        self.isGlobalTerminalExpanded = snapshot.isGlobalTerminalExpanded
        self.projectTerminal = TerminalSurfaceDescriptor(
            kind: .project,
            title: "Project Terminal",
            placeholderText: "Terminal placeholder for the selected thread"
        )
    }

    public var selectedThread: AgentThread? {
        threads.first { !$0.isArchived }
    }

    public func selectRightPanelMode(_ mode: RightPanelMode) {
        selectedRightPanelMode = mode
    }

    public func cycleRightPanelModeForward() {
        selectedRightPanelMode = selectedRightPanelMode.next
    }

    public func cycleRightPanelModeBackward() {
        selectedRightPanelMode = selectedRightPanelMode.previous
    }

    public func toggleGlobalTerminal() {
        isGlobalTerminalExpanded.toggle()
    }
}
