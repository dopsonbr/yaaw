import AgentIDEKit
import AppKit
import GhosttyTerminal
import SwiftUI

@available(macOS 14.0, *)
struct GhosttyTerminalSurfaceView: NSViewRepresentable {
    let request: TerminalLaunchRequest

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
        GhosttyTerminalStateRegistry.shared.configure(entry, for: request)
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
        configure(entry, for: request)
        return entry
    }

    func configure(_ entry: Entry, for request: TerminalLaunchRequest) {
        let options = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 13,
            workingDirectory: request.workingDirectory.path,
            context: .split
        )
        entry.state.configuration = options
        entry.view.delegate = entry.state
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
        case .nvim, .lazygit:
            break
        case .project, .global:
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

    final class Entry {
        let request: TerminalLaunchRequest
        let state: TerminalViewState
        let view: TerminalView

        init(request: TerminalLaunchRequest, state: TerminalViewState, view: TerminalView) {
            self.request = request
            self.state = state
            self.view = view
        }
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
