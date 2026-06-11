import AppKit
import SwiftUI
import YAAWKit

/// Pane that hosts a render surface for a role (or a placeholder when no surface
/// is available). The actual compositing + input live in `TerminalSurfaceHostView`;
/// this view layers the lifecycle overlay (launching / reconnecting / exited) on
/// top and is responsible for asking the client to (re)launch on appear.
struct TerminalPlaceholderView: View {
    @ObservedObject var client: RenderHostClient
    let role: RenderSurfaceRole?
    let title: String
    let unavailableMessage: String
    let fonts: FontSettings
    var onActivate: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let role {
                TerminalSurfaceHostView(client: client, role: role, fonts: fonts)
                    .accessibilityLabel("\(title) terminal")
                overlay(for: client.snapshot(for: role))
            } else {
                Text(unavailableMessage)
                    .font(fonts.editorFont())
                    .foregroundStyle(dracula(.foreground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
        .onAppear(perform: onActivate)
    }

    @ViewBuilder
    private func overlay(for snapshot: RenderSurfaceSnapshot) -> some View {
        switch snapshot.phase {
        case .idle, .launching:
            statusOverlay(
                title: "Starting agent terminal",
                message: "Running in an isolated helper process.",
                showRestart: false)
        case .reconnecting(let message):
            statusOverlay(title: "Reconnecting", message: message, showRestart: false)
        case .failed(let message):
            statusOverlay(title: "Render helper unavailable", message: message, showRestart: true)
        case .exited(let code):
            statusOverlay(
                title: "Agent exited",
                message: "Exit code \(code.map(String.init) ?? "unknown").",
                showRestart: true)
        case .ready:
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
                Button("Restart", action: onActivate)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dracula(.background))
    }
}

struct BottomTerminalBar: View {
    @ObservedObject var client: RenderHostClient
    let isExpanded: Bool
    let role: RenderSurfaceRole?
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
            .accessibilityIdentifier("toggle-bottom-terminal-button")
            .accessibilityLabel(isExpanded ? "Collapse bottom terminal" : "Expand bottom terminal")

            if isExpanded {
                TerminalPlaceholderView(
                    client: client,
                    role: role,
                    title: "Bottom",
                    unavailableMessage: "Terminal unavailable for the selected thread",
                    fonts: fonts,
                    onActivate: onAppearExpanded
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("bottom-terminal")
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

struct MissingDirectoryBanner: View {
    let title: String
    let path: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: IconRole.warning.icon.systemSymbolName)
                .font(.headline)
                .foregroundStyle(dracula(.orange))

            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(dracula(.cyan))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Text(message)
                .font(.caption)
                .foregroundStyle(dracula(.foreground))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dracula(.currentLine))
        .accessibilityLabel("\(title): \(path)")
    }
}
