import AgentIDEKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 250)

                Divider()
                    .overlay(dracula(.currentLine))

                MainWorkspaceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .overlay(dracula(.currentLine))

                RightPanelView(model: model)
                    .frame(width: 300)
            }

            GlobalTerminalBar(isExpanded: model.isGlobalTerminalExpanded)
        }
        .background(dracula(.background))
        .foregroundStyle(dracula(.foreground))
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent IDE")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.purple))

            VStack(alignment: .leading, spacing: 8) {
                Text("Projects")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))

                ForEach(model.projects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.displayName)
                            .lineLimit(1)

                        Text(project.rootDirectory.path)
                            .font(.caption)
                            .foregroundStyle(dracula(.comment))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Threads")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))

                ForEach(model.threads) { thread in
                    HStack {
                        Text(thread.displayName)
                            .lineLimit(1)

                        Spacer()

                        if thread.isArchived {
                            Text("Archived")
                                .font(.caption)
                                .foregroundStyle(dracula(.orange))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Spacer()
        }
        .padding(18)
        .background(dracula(.background))
    }
}

private struct MainWorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedThread?.displayName ?? "Hello World Thread")
                    .font(.title.weight(.semibold))

                Text("SwiftPM native macOS scaffold")
                    .foregroundStyle(dracula(.comment))
            }

            TerminalPlaceholderView(
                title: model.projectTerminal.title,
                message: model.projectTerminal.placeholderText
            )

            Spacer()
        }
        .padding(24)
        .background(dracula(.background))
    }
}

private struct RightPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(RightPanelMode.allCases) { mode in
                    Button {
                        model.selectRightPanelMode(mode)
                    } label: {
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(model.selectedRightPanelMode == mode ? dracula(.currentLine) : dracula(.background))
                    .foregroundStyle(model.selectedRightPanelMode == mode ? dracula(.pink) : dracula(.foreground))
                }
            }

            Divider()
                .overlay(dracula(.currentLine))

            switch model.selectedRightPanelMode {
            case .files:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files")
                        .font(.headline)

                    ForEach(SampleFileBrowser.sampleEntries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.isDirectory ? "Folder" : "File")
                                .font(.caption)
                                .foregroundStyle(dracula(entry.isDirectory ? .cyan : .green))
                                .frame(width: 46, alignment: .leading)

                            Text(entry.relativePath)
                                .lineLimit(1)
                        }
                    }
                }

            case .nvim:
                TerminalPlaceholderView(title: "nvim", message: "Terminal placeholder for nvim")

            case .git:
                TerminalPlaceholderView(title: "Git", message: "Terminal placeholder for lazygit")
            }

            Spacer()
        }
        .padding(18)
        .background(dracula(.background))
    }
}

private struct TerminalPlaceholderView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(dracula(.green))

            Text(message)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(dracula(.foreground))

            Text("Hello World")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(dracula(.yellow))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(dracula(.currentLine))
    }
}

private struct GlobalTerminalBar: View {
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Global Terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.purple))

                Spacer()

                Text(isExpanded ? "Expanded" : "Collapsed")
                    .font(.caption)
                    .foregroundStyle(dracula(.comment))
            }

            if isExpanded {
                TerminalPlaceholderView(title: "Global", message: "Terminal placeholder for the user home directory")
                    .frame(height: 120)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(dracula(.currentLine))
    }
}

private func dracula(_ role: DraculaRole) -> Color {
    Color(hex: DraculaTheme.hex(for: role))
}

private extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)

        self.init(
            red: Double((rgb >> 16) & 0xff) / 255.0,
            green: Double((rgb >> 8) & 0xff) / 255.0,
            blue: Double(rgb & 0xff) / 255.0
        )
    }
}
