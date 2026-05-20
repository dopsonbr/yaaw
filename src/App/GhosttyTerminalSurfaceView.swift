import AgentIDEKit
import AppKit
import GhosttyTerminal
import SwiftUI

@available(macOS 14.0, *)
struct GhosttyTerminalSurfaceView: NSViewRepresentable {
    let request: TerminalLaunchRequest
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attachTerminal(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachTerminal(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        for subview in nsView.subviews {
            if let terminal = subview as? TerminalView {
                terminal.setSurfaceVisible(false)
            }
            subview.removeFromSuperview()
        }
    }

    private func attachTerminal(to container: NSView) {
        let entry = GhosttyTerminalStateRegistry.shared.entry(for: request)
        let terminal = entry.view

        for subview in container.subviews where subview !== terminal {
            if let staleTerminal = subview as? TerminalView {
                staleTerminal.setSurfaceVisible(false)
            }
            subview.removeFromSuperview()
        }

        if terminal.superview !== container {
            terminal.removeFromSuperview()
            container.addSubview(terminal)
        }

        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        terminal.setSurfaceVisible(true)
        GhosttyTerminalStateRegistry.shared.configure(
            entry,
            for: request,
            onTitleChange: onTitleChange
        )
    }
}

@MainActor
enum GhosttyTerminalRuntime {
    static func closeAll() {
        if #available(macOS 14.0, *) {
            GhosttyTerminalStateRegistry.shared.closeAll()
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class GhosttyTerminalStateRegistry {
    static let shared = GhosttyTerminalStateRegistry()

    private var entriesByRole: [TerminalRole: Entry] = [:]
    private var pendingInitialCommands: Set<TerminalRole> = []
    private var sentInitialCommands: Set<TerminalRole> = []

    private init() {}

    func entry(for request: TerminalLaunchRequest) -> Entry {
        if let entry = entriesByRole[request.role], entry.request == request {
            return entry
        }

        let state = TerminalViewState(theme: draculaTerminalTheme, terminalConfiguration: draculaTerminalConfiguration)
        let view = TerminalView(frame: .zero)
        view.delegate = state
        let entry = Entry(request: request, state: state, view: view)
        entriesByRole[request.role] = entry
        sentInitialCommands.remove(request.role)
        configure(entry, for: request, onTitleChange: { _, _ in })
        return entry
    }

    func configure(
        _ entry: Entry,
        for request: TerminalLaunchRequest,
        onTitleChange: @escaping (TerminalRole, String) -> Void
    ) {
        let options = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 13,
            workingDirectory: request.workingDirectory.path,
            context: .split
        )
        entry.state.configuration = options
        entry.delegate.onTitleChange = { title in
            onTitleChange(request.role, title)
        }
        entry.view.delegate = entry.delegate
        entry.view.controller = entry.state.controller
        entry.view.configuration = options
        scheduleInitialCommandIfNeeded(for: request, state: entry.state)
    }

    func closeAll() {
        for entry in entriesByRole.values {
            entry.view.setSurfaceVisible(false)
            entry.view.removeFromSuperview()
        }
        entriesByRole.removeAll()
        pendingInitialCommands.removeAll()
        sentInitialCommands.removeAll()
    }

    private func scheduleInitialCommandIfNeeded(for request: TerminalLaunchRequest, state: TerminalViewState) {
        switch request.role {
        case .project, .nvim, .lazygit:
            break
        case .global:
            return
        }

        guard !pendingInitialCommands.contains(request.role),
              !sentInitialCommands.contains(request.role),
              !request.command.isEmpty
        else { return }
        pendingInitialCommands.insert(request.role)
        let role = request.role
        let commandLine = shellCommandLine(for: request.command) + "\r"

        Task { @MainActor [weak self, weak state] in
            guard let self else { return }
            defer { self.pendingInitialCommands.remove(role) }
            for _ in 0..<20 {
                guard let state else { return }
                if state.send(commandLine) {
                    self.sentInitialCommands.insert(role)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func shellCommandLine(for command: [String]) -> String {
        command.map { argument in
            if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'\\$`"))) == nil {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    @MainActor
    final class Entry {
        let request: TerminalLaunchRequest
        let state: TerminalViewState
        let view: TerminalView
        let delegate: AgentIDETerminalDelegate

        init(request: TerminalLaunchRequest, state: TerminalViewState, view: TerminalView) {
            self.request = request
            self.state = state
            self.view = view
            self.delegate = AgentIDETerminalDelegate(state: state)
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class AgentIDETerminalDelegate:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate
{
    private let state: TerminalViewState
    var onTitleChange: (String) -> Void = { _ in }

    init(state: TerminalViewState) {
        self.state = state
    }

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
        onTitleChange(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state.terminalDidChangeFocus(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        state.terminalDidClose(processAlive: processAlive)
    }

    func terminalDidRingBell() {
        state.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state.terminalDidChangeWorkingDirectory(path)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }
}

@available(macOS 14.0, *)
private let draculaTerminalTheme = TerminalTheme(
    light: draculaTerminalConfiguration,
    dark: draculaTerminalConfiguration
)

@available(macOS 14.0, *)
private let draculaTerminalConfiguration = TerminalConfiguration { config in
    config.withBackground(draculaHex(.background))
    config.withForeground(draculaHex(.foreground))
    config.withSelectionBackground(draculaHex(.currentLine))
    config.withSelectionForeground(draculaHex(.foreground))
    config.withCursorColor(draculaHex(.pink))
    config.withCursorText(draculaHex(.background))
    config.withBoldColor(draculaHex(.yellow))
    config.withFontSize(13)
    config.withWindowPaddingX(10)
    config.withWindowPaddingY(8)
}

private func draculaHex(_ role: DraculaRole) -> String {
    DraculaTheme.hex(for: role).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
}
