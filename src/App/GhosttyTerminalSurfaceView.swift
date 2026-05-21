import YAAWKit
import AppKit
import GhosttyTerminal
import SwiftUI

@available(macOS 14.0, *)
struct GhosttyTerminalSurfaceView: NSViewRepresentable {
    let request: TerminalLaunchRequest
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
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

        terminal.autoresizingMask = [.width, .height]
        terminal.frame = container.bounds
        if let terminalContainer = container as? TerminalContainerView {
            terminalContainer.terminalView = terminal
            terminalContainer.request = request
            terminalContainer.registerTerminalForPaste()
        }
        terminal.fitToSize()
        terminal.setSurfaceVisible(true)
        if let terminalContainer = container as? TerminalContainerView {
            terminalContainer.focusTerminalIfPossible()
        }
        GhosttyTerminalStateRegistry.shared.configure(
            entry,
            for: request,
            onTitleChange: onTitleChange
        )
    }
}

@available(macOS 14.0, *)
private final class TerminalContainerView: NSView {
    weak var terminalView: TerminalView?
    var request: TerminalLaunchRequest?

    override func layout() {
        super.layout()
        guard let terminalView else { return }
        terminalView.frame = bounds
        terminalView.fitToSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            TerminalImagePasteBridge.shared.unregister(container: self)
        } else {
            registerTerminalForPaste()
        }
    }

    func registerTerminalForPaste() {
        guard let terminalView, let request else { return }
        TerminalImagePasteBridge.shared.register(
            container: self,
            terminalView: terminalView,
            request: request
        )
    }

    func focusTerminalIfPossible() {
        guard let terminalView else { return }
        DispatchQueue.main.async { [weak terminalView] in
            guard let terminalView,
                  terminalView.window?.isKeyWindow == true
            else {
                return
            }
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class TerminalImagePasteBridge {
    static let shared = TerminalImagePasteBridge()

    private let imageStore = YAAWPastedImageStore()
    private let pasteFormatter = TerminalPasteTextFormatter()
    private var keyMonitor: Any?
    private var registrations: [ObjectIdentifier: Registration] = [:]

    private init() {}

    func register(
        container: TerminalContainerView,
        terminalView: TerminalView,
        request: TerminalLaunchRequest
    ) {
        registrations[ObjectIdentifier(container)] = Registration(
            container: container,
            terminalView: terminalView,
            request: request
        )
        installKeyMonitorIfNeeded()
    }

    func unregister(container: TerminalContainerView) {
        registrations.removeValue(forKey: ObjectIdentifier(container))
        if registrations.isEmpty {
            removeKeyMonitor()
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handlePasteShortcut(event) ?? event
        }
    }

    private func handlePasteShortcut(_ event: NSEvent) -> NSEvent? {
        guard TerminalPasteShortcut.matches(event),
              let registration = focusedRegistration(in: event.window),
              let terminalView = registration.terminalView,
              let pngData = PasteboardImageExtractor.pngData(from: .general),
              let imageURL = try? imageStore.savePNGData(pngData, role: registration.request.role)
        else {
            return event
        }

        let agentCLI = registration.request.agentCLI ?? .codex
        let text = pasteFormatter.text(for: .image(imageURL), agentCLI: agentCLI)
        terminalView.sendText(text)
        return nil
    }

    private func focusedRegistration(in eventWindow: NSWindow?) -> Registration? {
        registrations.values.first { registration in
            guard let container = registration.container,
                  let terminalView = registration.terminalView,
                  terminalView.window === eventWindow,
                  container.window === eventWindow
            else {
                return false
            }
            return eventWindow?.firstResponder === terminalView
        }
    }

    private struct Registration {
        weak var container: TerminalContainerView?
        weak var terminalView: TerminalView?
        var request: TerminalLaunchRequest
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

    private init() {}

    func entry(for request: TerminalLaunchRequest) -> Entry {
        if let entry = entriesByRole[request.role], entry.request == request {
            return entry
        }

        let state = TerminalViewState(
            theme: draculaTerminalTheme,
            terminalConfiguration: terminalConfiguration(for: request)
        )
        let view = TerminalView(frame: .zero)
        view.delegate = state
        let entry = Entry(request: request, state: state, view: view)
        entriesByRole[request.role] = entry
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
            fontSize: 12,
            workingDirectory: request.workingDirectory.path,
            context: .split
        )
        entry.state.configuration = options
        entry.state.controller.setTerminalConfiguration(terminalConfiguration(for: request))
        entry.delegate.onTitleChange = { title in
            onTitleChange(request.role, title)
        }
        entry.view.delegate = entry.delegate
        entry.view.controller = entry.state.controller
        entry.view.configuration = options
    }

    func closeAll() {
        for entry in entriesByRole.values {
            entry.view.setSurfaceVisible(false)
            entry.view.removeFromSuperview()
        }
        entriesByRole.removeAll()
    }

    private func terminalConfiguration(for request: TerminalLaunchRequest) -> TerminalConfiguration {
        guard !request.command.isEmpty else { return draculaTerminalConfiguration }
        return draculaTerminalConfiguration.custom("command", shellCommandLine(for: request.command))
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
        let delegate: YAAWTerminalDelegate

        init(request: TerminalLaunchRequest, state: TerminalViewState, view: TerminalView) {
            self.request = request
            self.state = state
            self.view = view
            self.delegate = YAAWTerminalDelegate(state: state)
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class YAAWTerminalDelegate:
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
    config.withFontSize(12)
    config.withWindowPaddingX(0)
    config.withWindowPaddingY(0)
}

private func draculaHex(_ role: DraculaRole) -> String {
    DraculaTheme.hex(for: role).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
}
