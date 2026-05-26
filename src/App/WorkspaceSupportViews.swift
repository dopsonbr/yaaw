import AppKit
import SwiftUI
import YAAWKit

struct TerminalPlaceholderView: View {
    let request: TerminalLaunchRequest?
    let unavailableMessage: String
    let fonts: FontSettings
    var onTitleChange: (TerminalRole, String) -> Void = { _, _ in }
    var onDesktopNotification: (TerminalRole, String, String) -> Void = { _, _, _ in }
    var onFocusChange: (TerminalRole, Bool) -> Void = { _, _ in }
    var onClose: (TerminalRole) -> Void = { _ in }
    var onCommandFinished: (TerminalRole, Int?) -> Void = { _, _ in }
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let request {
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
            } else {
                Text(unavailableMessage)
                    .font(fonts.editorFont())
                    .foregroundStyle(dracula(.foreground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dracula(.cyan))
            .help(accessibilityLabel)
            .accessibilityLabel(accessibilityLabel)

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
