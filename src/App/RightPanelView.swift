import AppKit
import SwiftUI
import YAAWKit

/// The right tool panel: a horizontal tab strip (Files / Browser / nvim / Git)
/// with an add menu, over the selected tab's content. Consumes `RightPanelStore`
/// (tabs/modes), `ActivityStore` (file-browser state), `WorkspaceStore`
/// (selection / working directory), and `RenderHostClient` (nvim/git surfaces).
struct RightPanelView: View {
    let workspace: WorkspaceStore
    let activity: ActivityStore
    let rightPanel: RightPanelStore
    @ObservedObject var renderHostClient: RenderHostClient
    let settings: SettingsStore
    let defaultExternalEditorTool: ExternalOpenToolID?
    let onOpenFileExternally: (FileBrowserEntry, ExternalOpenToolID) -> Void
    let onCopyPath: (FileBrowserEntry, FileBrowserCopyPathStyle) -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            tabContent
        }
        .background(dracula(.background))
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(rightPanel.selectedRightPanelState.tabs) { tab in
                    rightPanelTabButton(tab)
                }
                addTabMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
    }

    private var addTabMenu: some View {
        Menu {
            Button {
                rightPanel.selectRightPanelTab(id: RightPanelTab.filesID)
            } label: {
                Label(
                    "Files", systemImage: IconRole.rightPanelMode(.files).icon.systemSymbolName)
            }
            Button {
                rightPanel.openBrowserTab()
            } label: {
                Label(
                    "Web Browser",
                    systemImage: IconRole.rightPanelMode(.browser).icon.systemSymbolName)
            }
            Button {
                chooseNvimFile()
            } label: {
                Label(
                    "nvim File...",
                    systemImage: IconRole.rightPanelMode(.nvim).icon.systemSymbolName)
            }
            Button {
                rightPanel.selectRightPanelTab(id: RightPanelTab.gitID)
            } label: {
                Label("Git", systemImage: IconRole.rightPanelMode(.git).icon.systemSymbolName)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: IconRole.add.icon.systemSymbolName)
                Image(systemName: IconRole.disclosureExpanded.icon.systemSymbolName)
                    .font(.system(size: 9, weight: ChromeMetrics.glyphWeight))
            }
            .font(.system(size: ChromeMetrics.toolbarGlyph, weight: ChromeMetrics.glyphWeight))
            .frame(width: 38, height: 32)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .foregroundStyle(dracula(.foreground))
        .background(dracula(.background))
        .help("Open a new right tool panel tab")
        .accessibilityLabel("Open a new right tool panel tab")
        .accessibilityIdentifier("right-panel-add-tab-button")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch rightPanel.selectedRightPanelTab.kind {
        case .files:
            filesPanel
        case .browser:
            BrowserPanelPlaceholder(
                client: renderHostClient,
                role: selectedRightPanelRole,
                tab: rightPanel.selectedRightPanelTab,
                unavailableMessage: rightPanel.selectedBrowserUnavailableMessage,
                onNavigate: rightPanel.updateSelectedBrowserTab(urlString:),
                onActivate: activateSelectedRightPanelTerminal
            )
            .id(
                "\(workspace.selectedThreadID?.uuidString ?? "none")-\(rightPanel.selectedRightPanelTab.id)-\(rightPanel.selectedRightPanelTab.urlString ?? "")"
            )
            .accessibilityIdentifier("browser-panel")
        case .nvim:
            TerminalPlaceholderView(
                client: renderHostClient,
                role: selectedRightPanelRole,
                title: "nvim",
                unavailableMessage: unavailableMessage(tool: "nvim"),
                fonts: settings.configuration.fonts,
                onActivate: activateSelectedRightPanelTerminal
            )
            .id(
                "\(workspace.selectedThreadID?.uuidString ?? "none")-\(rightPanel.selectedRightPanelTab.id)"
            )
            .accessibilityIdentifier("nvim-panel")
        case .git:
            TerminalPlaceholderView(
                client: renderHostClient,
                role: selectedRightPanelRole,
                title: "Git",
                unavailableMessage: unavailableMessage(tool: "lazygit"),
                fonts: settings.configuration.fonts,
                onActivate: activateSelectedRightPanelTerminal
            )
            .id(workspace.selectedThreadID)
            .accessibilityIdentifier("git-panel")
        }
    }

    private var filesPanel: some View {
        FileBrowserPanel(
            state: activity.fileBrowserState,
            searchQuery: Binding(
                get: { activity.fileBrowserState.searchQuery },
                set: { activity.updateFileSearchQuery($0) }
            ),
            expandedFolders: Binding(
                get: {
                    workspace.selectedThreadID.map { rightPanel.expandedFolders(forThreadID: $0) }
                        ?? []
                },
                set: { newValue in
                    if let id = workspace.selectedThreadID {
                        rightPanel.setExpandedFolders(newValue, forThreadID: id)
                    }
                }
            ),
            selectedRelativePath: rightPanel.selectedFileRelativePath,
            fileIconPack: settings.configuration.fileIconPack,
            onRefresh: activity.refreshSelectedFileBrowser,
            onSelectFile: { activity.selectFile(relativePath: $0.relativePath) },
            onOpenFile: {
                rightPanel.openFileFromBrowserPrimary(
                    relativePath: $0.relativePath,
                    markdownAndHTMLToBrowser: markdownAndHTMLToBrowser)
            },
            onOpenInBrowser: { rightPanel.openFileInBrowser(relativePath: $0.relativePath) },
            defaultExternalEditorTool: defaultExternalEditorTool,
            onOpenExternally: onOpenFileExternally,
            onCopyPath: onCopyPath
        )
        .accessibilityIdentifier("files-panel")
        .onAppear { activity.refreshSelectedFileBrowser() }
    }

    // MARK: - Tab button

    private func rightPanelTabButton(_ tab: RightPanelTab) -> some View {
        let isSelected = rightPanel.selectedRightPanelTab.id == tab.id
        let showsTitle = isSelected && shouldShowTabTitle(tab)
        return HStack(spacing: 4) {
            Button {
                rightPanel.selectRightPanelTab(id: tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: IconRole.rightPanelMode(mode(for: tab.kind)).icon
                            .systemSymbolName
                    )
                    .font(
                        .system(size: ChromeMetrics.toolbarGlyph, weight: ChromeMetrics.glyphWeight)
                    )
                    .frame(width: 22, height: 32)

                    if showsTitle {
                        Text(tab.title)
                            .font(fonts.interfaceFont(sizeOffset: -2, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150, alignment: .leading)
                    }
                }
                .padding(.leading, showsTitle ? 8 : 6)
                .padding(.trailing, isSelected && tab.isClosable ? 0 : (showsTitle ? 8 : 6))
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("right-panel-tab-\(tab.kind.rawValue)")

            if isSelected, tab.isClosable {
                Button {
                    rightPanel.closeRightPanelTab(id: tab.id)
                } label: {
                    Image(systemName: IconRole.close.icon.systemSymbolName)
                        .font(.system(size: 11, weight: ChromeMetrics.glyphWeight))
                        .frame(width: 18, height: 32)
                }
                .buttonStyle(.plain)
                .help("Close \(tab.title) tab")
                .accessibilityLabel("Close \(tab.title) tab")
            }
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                .fill(ChromeMetrics.pillFill(selected: isSelected, hovering: false))
        )
        .foregroundStyle(isSelected ? dracula(.pink) : dracula(.foreground))
        .help(tab.title)
        .accessibilityLabel("\(tab.title) right tool panel tab")
        .contextMenu {
            if tab.isClosable {
                Button("Close Tab") { rightPanel.closeRightPanelTab(id: tab.id) }
            }
        }
    }
}

// MARK: - Helpers

// In an extension so the primary `RightPanelView` body stays under the
// type-body-length limit; same-file `private` members remain accessible to the
// struct's view builders above.
extension RightPanelView {
    private var markdownAndHTMLToBrowser: Bool {
        settings.configuration.fileBrowser.markdownAndHTMLDefault == .browserPreview
    }

    private var selectedRightPanelRole: RenderSurfaceRole? {
        guard let threadID = workspace.selectedThreadID else { return nil }
        let tab = rightPanel.selectedRightPanelTab
        switch tab.kind {
        case .files:
            return nil
        case .browser:
            // A browser tab drives a render surface only once it has a URL to
            // load; an empty browser tab shows the "Enter a URL" chrome instead.
            guard let urlString = tab.urlString, !urlString.isEmpty else { return nil }
            return .browser(threadID: threadID, tabID: tab.id)
        case .git:
            return .lazygit(threadID: threadID)
        case .nvim:
            return .nvimTab(threadID: threadID, tabID: tab.id)
        }
    }

    private func activateSelectedRightPanelTerminal() {
        guard let role = selectedRightPanelRole else { return }
        workspace.activateTerminal(role: role)
    }

    private func unavailableMessage(tool: String) -> String {
        if case .missing(let path) = workspace.selectedThreadWorkingDirectoryState {
            return "Missing working directory for \(tool): \(path)"
        }
        return "Terminal unavailable for \(tool)"
    }

    private func shouldShowTabTitle(_ tab: RightPanelTab) -> Bool {
        switch tab.kind {
        case .browser:
            return tab.title != RightPanelTab.defaultBrowser.title
        case .nvim:
            return tab.title != RightPanelTab.defaultNvim.title
        case .files, .git:
            return false
        }
    }

    private func mode(for kind: RightPanelTabKind) -> RightPanelMode {
        switch kind {
        case .files: .files
        case .browser: .browser
        case .git: .git
        case .nvim: .nvim
        }
    }

    private func chooseNvimFile() {
        guard let root = workspace.selectedThread?.workingDirectory else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            let rootPath = root.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { return }
            rightPanel.openFileInNvim(relativePath: String(filePath.dropFirst(rootPath.count + 1)))
        }
    }
}

/// Browser tab UI. The web surface runs in an isolated render helper (wired at
/// integration); this shell renders the address bar + navigation affordances and
/// surfaces the unavailable message. (Delete-by-omission: no in-process WKWebView,
/// no floating window, no viewport polling.)
struct BrowserPanelPlaceholder: View {
    @ObservedObject var client: RenderHostClient
    let role: RenderSurfaceRole?
    let tab: RightPanelTab
    let unavailableMessage: String?
    let onNavigate: (String) -> Void
    var onActivate: () -> Void = {}
    @State private var addressText = ""
    @FocusState private var isAddressFocused: Bool
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search or enter website", text: $addressText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(dracula(.currentLine))
                    .foregroundStyle(dracula(.foreground))
                    .focused($isAddressFocused)
                    .onSubmit { onNavigate(addressText) }
                    .accessibilityLabel("Browser address")
                    .accessibilityIdentifier("browser-address-field")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            Divider().overlay(dracula(.currentLine))

            if let unavailableMessage {
                MissingDirectoryBanner(
                    title: "Browser preview unavailable",
                    path: tab.relativePath ?? tab.urlString ?? "Browser",
                    message: unavailableMessage
                )
                Spacer()
            } else if let role, let urlString = tab.urlString, !urlString.isEmpty {
                // The web content renders out-of-process: the helper rasterizes its
                // WKWebView into a shared IOSurface that this surface host composites
                // as the pane layer (ADR-004 Candidate 2 — same wire path as the
                // terminal). The loading overlay sits on top until the first frame.
                ZStack {
                    TerminalSurfaceHostView(client: client, role: role, fonts: fonts)
                        .accessibilityLabel("Browser preview")
                    if client.snapshot(for: role).phase != .ready {
                        browserLoadingOverlay(urlString: urlString)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dracula(.background))
            } else if let urlString = tab.urlString, !urlString.isEmpty {
                browserLoadingOverlay(urlString: urlString)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(dracula(.background))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: IconRole.rightPanelMode(.browser).icon.systemSymbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(dracula(.cyan))
                    Text("Enter a URL")
                        .font(fonts.interfaceFont(weight: .semibold))
                        .foregroundStyle(dracula(.foreground))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dracula(.background))
            }
        }
        .background(dracula(.background))
        .onAppear {
            addressText = tab.urlString ?? ""
            if tab.urlString?.isEmpty ?? true { isAddressFocused = true }
            onActivate()
        }
        .onChange(of: tab.id) {
            addressText = tab.urlString ?? ""
            onActivate()
        }
        .onChange(of: tab.urlString) {
            addressText = tab.urlString ?? ""
            onActivate()
        }
        .task(id: activationKey) {
            onActivate()
        }
    }

    @ViewBuilder
    private func browserLoadingOverlay(urlString: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: IconRole.rightPanelMode(.browser).icon.systemSymbolName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(dracula(.cyan))
            Text("Loading \(urlString)")
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("The browser runs in an isolated helper process.")
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
        }
    }

    private var activationKey: String {
        "\(role.map(String.init(describing:)) ?? "nil")|\(tab.urlString ?? "")"
    }
}
