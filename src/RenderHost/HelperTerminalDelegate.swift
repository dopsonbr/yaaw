import Foundation
import GhosttyTerminal
import YAAWRenderProtocol

/// Forwards Ghostty surface delegate callbacks to the ``TerminalViewState`` (so
/// the surface renders/tracks state correctly) and re-emits the app-facing
/// subset as typed ``RenderEvent``s over the reply channel.
///
/// `terminalDidChangeFocus`/`terminalDidClose` are *not* re-emitted: the helper
/// is faceless (focus is the app's concern) and process exit is reported
/// authoritatively by ``AgentTerminalProcess``'s `onExit`, not the surface
/// close callback (which only signals the emulator detaching).
@MainActor
final class HelperTerminalDelegate:
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
    private let reply: RenderEventReply

    /// Called when the Ghostty surface attaches (its `CAMetalLayer` now exists),
    /// so the controller can publish the remote `contextID` — the layer is nil at
    /// controller-init time, so publishing only there never sends a frame.
    var onSurfaceAttached: (@MainActor () -> Void)?

    init(state: TerminalViewState, reply: RenderEventReply) {
        self.state = state
        self.reply = reply
    }

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
        reply.send(.title(title))
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
        reply.send(.bell)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
        reply.send(.notification(title: title, body: body))
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state.terminalDidChangeWorkingDirectory(path)
        reply.send(.pwd(path))
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        // Per-command completion via shell integration (not process exit) — the
        // app uses it for activity tracking.
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
        reply.send(.commandFinished(exitCode: exitCode, durationNanos: durationNanos))
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
        onSurfaceAttached?()
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }
}
