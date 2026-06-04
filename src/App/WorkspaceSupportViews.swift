import AppKit
import SwiftUI
import YAAWKit

struct TerminalPlaceholderView: View {
    let request: TerminalLaunchRequest?
    let unavailableMessage: String
    let fonts: FontSettings
    /// When true and the request is an agent PTY, render the terminal in an
    /// isolated helper process instead of in-process.
    var useIsolatedTerminal: Bool = false
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }
    var onDesktopNotification: (TerminalRole, String, String) -> Void = { _, _, _ in }
    var onFocusChange: (TerminalRole, Bool) -> Void = { _, _ in }
    var onClose: (TerminalRole) -> Void = { _ in }
    var onCommandFinished: (TerminalRole, Int?) -> Void = { _, _ in }
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var terminalRuntime: IsolatedToolRuntime

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let request {
                if useIsolatedTerminal, case .agentPTY(let descriptor) = request.backend {
                    IsolatedAgentTerminalView(
                        runtime: terminalRuntime,
                        role: request.role,
                        launch: Self.launch(for: request, descriptor: descriptor),
                        fonts: fonts
                    )
                    .accessibilityLabel("\(request.title) terminal")
                } else {
                    GhosttyTerminalSurfaceView(
                        request: request,
                        theme: appTheme,
                        fonts: fonts,
                        onTitleChange: onTitleChange,
                        onDesktopNotification: onDesktopNotification,
                        onFocusChange: onFocusChange,
                        onClose: onClose,
                        onCommandFinished: onCommandFinished
                    )
                    .accessibilityLabel("\(request.title) terminal")
                }
            } else {
                Text(unavailableMessage)
                    .font(fonts.editorFont())
                    .foregroundStyle(dracula(.foreground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }

    private static func launch(
        for request: TerminalLaunchRequest,
        descriptor: AgentTerminalLaunchDescriptor
    ) -> IsolatedTerminalLaunch {
        IsolatedTerminalLaunch(
            command: descriptor.command,
            environment: descriptor.environment,
            workingDirectory: request.workingDirectory.path,
            captureLogPath: descriptor.captureLogURL?.path,
            captureLogMaximumBytes: Int(descriptor.captureLogMaximumBytes),
            startupInput: descriptor.startupInput,
            agentCLI: request.agentCLI?.rawValue
        )
    }
}

/// Renders an agent terminal that is hosted out-of-process: this view only
/// reports the pane's screen frame so the helper can position its overlay
/// window. The helper owns the PTY, ghostty surface, and capture log; AppModel
/// still derives title/activity by polling that capture log. The helper persists
/// while the thread is live (it is NOT torn down when this pane disappears).
struct IsolatedAgentTerminalView: View {
    @ObservedObject var runtime: IsolatedToolRuntime
    let role: TerminalRole
    let launch: IsolatedTerminalLaunch
    let fonts: FontSettings

    private var instanceID: String { role.isolatedInstanceID }
    private var snapshot: IsolatedToolRuntimeSnapshot { runtime.snapshot(for: instanceID) }

    var body: some View {
        ZStack {
            Color.black

            IsolatedToolViewportReporter { frame, visible in
                runtime.terminalSetViewport(instanceID: instanceID, frame: frame, visible: visible)
            }
            .allowsHitTesting(false)

            overlay
        }
        .onAppear {
            runtime.ensureTerminalLaunched(instanceID: instanceID, launch: launch)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch snapshot.phase {
        case .idle, .launching:
            statusOverlay(
                title: "Starting agent terminal",
                message: "Running in an isolated helper process.",
                showRestart: false)
        case .crashed:
            statusOverlay(
                title: "Agent terminal crashed",
                message: snapshot.errorMessage ?? "The terminal helper exited unexpectedly.",
                showRestart: true)
        case .exited:
            statusOverlay(
                title: "Agent exited",
                message: "Exit code \(snapshot.exitCode.map(String.init) ?? "unknown").",
                showRestart: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusOverlay(title: String, message: String, showRestart: Bool) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(fonts.interfaceFont(weight: .semibold))
                .foregroundStyle(dracula(.foreground))
            Text(message)
                .font(fonts.interfaceFont())
                .foregroundStyle(dracula(.comment))
                .multilineTextAlignment(.center)
            if showRestart {
                Button("Restart") {
                    runtime.terminalShutdown(instanceID: instanceID)
                    runtime.ensureTerminalLaunched(instanceID: instanceID, launch: launch)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dracula(.background))
    }
}

struct BottomTerminalBar: View {
    let isExpanded: Bool
    let request: TerminalLaunchRequest?
    let fonts: FontSettings
    let onToggle: () -> Void
    let onAppearExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack {
                    Text("Bottom Terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(dracula(.purple))

                    Spacer()

                    Text(isExpanded ? "Expanded" : "Collapsed")
                        .font(.caption)
                        .foregroundStyle(dracula(.comment))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse bottom terminal" : "Expand bottom terminal")

            if isExpanded {
                TerminalPlaceholderView(
                    request: request,
                    unavailableMessage: "Terminal unavailable for the selected thread",
                    fonts: fonts
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear(perform: onAppearExpanded)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(dracula(.currentLine))
    }
}

struct CollapsedPanelRail: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        VStack {
            ChromeIconButton(
                systemImage: systemImage,
                tint: dracula(.cyan),
                help: accessibilityLabel,
                action: action
            )

            Spacer()
        }
        .padding(.vertical, 14)
        .background(dracula(.background))
    }
}

struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateTitle(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateTitle(from: nsView)
    }

    private func updateTitle(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}
