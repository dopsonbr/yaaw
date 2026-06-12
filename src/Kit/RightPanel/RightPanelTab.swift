import Foundation

/// The category of content a right panel tab displays.
public enum RightPanelTabKind: String, Equatable, Sendable {
    /// A file browser tab.
    case files
    /// A web/file browser preview tab.
    case browser
    /// A Git (lazygit) tab.
    case git
    /// An nvim editor tab.
    case nvim
}

/// A single tab shown in the right panel, identified by a stable id and backed by a kind.
public struct RightPanelTab: Identifiable, Equatable, Sendable {
    /// The id of the singleton Files tab.
    public static let filesID = "files"
    /// The id of the default Browser tab.
    public static let defaultBrowserID = "browser"
    /// The id of the singleton Git tab.
    public static let gitID = "git"
    /// The id of the default nvim tab.
    public static let defaultNvimID = "nvim"

    /// The stable identifier for this tab.
    public var id: String
    /// The kind of content this tab displays.
    public var kind: RightPanelTabKind
    /// The title shown on the tab.
    public var title: String
    /// The project-relative path the tab is bound to, if any.
    public var relativePath: String?
    /// The URL the tab displays, if any.
    public var urlString: String?

    /// Creates a right panel tab with the given identity and content.
    public init(
        id: String,
        kind: RightPanelTabKind,
        title: String,
        relativePath: String? = nil,
        urlString: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.relativePath = relativePath
        self.urlString = urlString
    }

    /// The singleton Files tab.
    public static let files = RightPanelTab(id: filesID, kind: .files, title: "Files")
    /// The default Browser tab.
    public static let defaultBrowser = RightPanelTab(
        id: defaultBrowserID, kind: .browser, title: "Browser")
    /// The singleton Git tab.
    public static let git = RightPanelTab(id: gitID, kind: .git, title: "Git")
    /// The default nvim tab.
    public static let defaultNvim = RightPanelTab(id: defaultNvimID, kind: .nvim, title: "nvim")

    /// Whether the user can close this tab; the default singleton tabs are not closable.
    public var isClosable: Bool {
        switch id {
        case Self.filesID, Self.defaultBrowserID, Self.gitID, Self.defaultNvimID:
            false
        default:
            kind == .browser || kind == .nvim
        }
    }

    /// Creates an nvim tab for the given project-relative file path.
    public static func nvim(relativePath: String) -> RightPanelTab {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        return RightPanelTab(
            id: nvimTabID(relativePath: normalizedPath),
            kind: .nvim,
            title: URL(fileURLWithPath: normalizedPath).lastPathComponent,
            relativePath: normalizedPath
        )
    }

    /// Returns the stable tab id for an nvim tab bound to the given relative path.
    public static func nvimTabID(relativePath: String) -> String {
        "nvim:\(FilePathNormalizer.normalizedRelativePath(relativePath))"
    }

    /// Creates a browser tab for the given URL and/or project-relative file path,
    /// optionally reusing an explicit id.
    public static func browser(urlString: String?, relativePath: String? = nil, id: String? = nil)
        -> RightPanelTab
    {
        let normalizedPath = relativePath.map(FilePathNormalizer.normalizedRelativePath)
        let normalizedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RightPanelTab(
            id: id ?? browserTabID(urlString: normalizedURL, relativePath: normalizedPath),
            kind: .browser,
            title: browserTitle(urlString: normalizedURL, relativePath: normalizedPath),
            relativePath: normalizedPath,
            urlString: normalizedURL
        )
    }

    /// Returns the stable tab id for a browser tab bound to the given file path or URL.
    public static func browserTabID(urlString: String?, relativePath: String?) -> String {
        if let relativePath, !relativePath.isEmpty {
            return "browser-file:\(FilePathNormalizer.normalizedRelativePath(relativePath))"
        }
        if let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
            !urlString.isEmpty
        {
            return "browser-url:\(urlString)"
        }
        return "browser-blank:\(UUID().uuidString)"
    }

    private static func browserTitle(urlString: String?, relativePath: String?) -> String {
        if let relativePath, !relativePath.isEmpty {
            return URL(fileURLWithPath: relativePath).lastPathComponent
        }
        guard let urlString, !urlString.isEmpty else { return "Browser" }
        if let url = URL(string: urlString) {
            if url.isFileURL {
                let fileName = url.lastPathComponent
                return fileName.isEmpty ? "Local file" : fileName
            }
            if let host = url.host, !host.isEmpty {
                let readableHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let pathComponents = url.pathComponents.filter { $0 != "/" }
                let readablePath = pathComponents.prefix(2).joined(separator: "/")
                let title = readablePath.isEmpty ? readableHost : "\(readableHost)/\(readablePath)"
                return shortened(title, maximumLength: 38)
            }
        }
        return shortened(urlString, maximumLength: 38)
    }

    private static func shortened(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength, maximumLength > 8 else { return value }
        let headCount = (maximumLength - 1) / 2
        let tailCount = maximumLength - headCount - 1
        return "\(value.prefix(headCount))...\(value.suffix(tailCount))"
    }
}

/// The full state of a thread's right panel: its open tabs, selection, and persisted UI state.
public struct RightPanelState: Equatable, Sendable {
    /// The tabs currently open in the right panel.
    public var tabs: [RightPanelTab]
    /// The id of the currently selected tab.
    public var selectedTabID: String
    /// Folders the user has expanded in the file browser, by relative path.
    /// Persisted per thread (schema v18) so expansion survives relaunch.
    public var expandedFolders: Set<String>
    /// The last file the user selected in the file browser, by relative path.
    /// Persisted per thread (schema v18).
    public var selectedFilePath: String?
    /// The last file opened in nvim, by relative path. Persisted per thread
    /// (schema v18).
    public var nvimPath: String?

    /// Creates a right panel state, normalizing the tabs and clamping the selection to an open tab.
    public init(
        tabs: [RightPanelTab] = RightPanelState.defaultTabs,
        selectedTabID: String = RightPanelTab.filesID,
        expandedFolders: Set<String> = [],
        selectedFilePath: String? = nil,
        nvimPath: String? = nil
    ) {
        self.tabs = Self.normalizedTabs(tabs)
        self.selectedTabID =
            self.tabs.contains { $0.id == selectedTabID }
            ? selectedTabID
            : RightPanelTab.filesID
        self.expandedFolders = expandedFolders
        self.selectedFilePath = selectedFilePath
        self.nvimPath = nvimPath
    }

    /// The default set of tabs: Files, Browser, Git, and nvim.
    public static let defaultTabs: [RightPanelTab] = [
        .files,
        .defaultBrowser,
        .git,
        .defaultNvim,
    ]

    /// Returns a default state with the given mode selected.
    public static func defaultState(selectedMode: RightPanelMode = .files) -> RightPanelState {
        RightPanelState(selectedTabID: selectedMode.defaultTabID)
    }

    /// Rebuilds a state on load from persisted tabs and selection, with no per-thread UI state.
    public static func restoredState(tabs: [RightPanelTab], selectedTabID: String)
        -> RightPanelState
    {
        restoredState(
            tabs: tabs,
            selectedTabID: selectedTabID,
            expandedFolders: [],
            selectedFilePath: nil,
            nvimPath: nil
        )
    }

    /// Rebuilds a state on load, restoring the now-persisted per-thread UI state
    /// (schema v18: expanded folders, selected file, nvim path).
    public static func restoredState(
        tabs: [RightPanelTab],
        selectedTabID: String,
        expandedFolders: Set<String>,
        selectedFilePath: String?,
        nvimPath: String?
    ) -> RightPanelState {
        let selectedKind = tabs.first { $0.id == selectedTabID }?.kind
        let selectedMode = selectedKind?.mode ?? .files
        var state = RightPanelState.defaultState(selectedMode: selectedMode)
        state.expandedFolders = expandedFolders
        state.selectedFilePath = selectedFilePath
        state.nvimPath = nvimPath
        return state
    }

    /// A version of this state suitable for persistence: default tabs plus the saved per-thread UI state.
    public var persistenceSnapshot: RightPanelState {
        var snapshot = RightPanelState.defaultState(selectedMode: selectedMode)
        snapshot.expandedFolders = expandedFolders
        snapshot.selectedFilePath = selectedFilePath
        snapshot.nvimPath = nvimPath
        return snapshot
    }

    /// The currently selected tab, falling back to the Files tab if none matches.
    public var selectedTab: RightPanelTab {
        tabs.first { $0.id == selectedTabID } ?? .files
    }

    /// The right panel mode corresponding to the selected tab.
    public var selectedMode: RightPanelMode {
        selectedTab.kind.mode
    }

    /// Selects the default tab for the given mode.
    public mutating func selectMode(_ mode: RightPanelMode) {
        selectedTabID = mode.defaultTabID
    }

    /// Selects the tab with the given id, if it is open.
    public mutating func selectTab(id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    /// Opens (or reuses) an nvim tab for the given relative path, selects it, and returns it.
    public mutating func openNvimTab(relativePath: String) -> RightPanelTab {
        let tab = RightPanelTab.nvim(relativePath: relativePath)
        if !tabs.contains(where: { $0.id == tab.id }) {
            tabs.append(tab)
            tabs = Self.normalizedTabs(tabs)
        }
        selectedTabID = tab.id
        return tab
    }

    /// Opens (or reuses) a browser tab for the given URL and/or relative path, selects it, and returns it.
    public mutating func openBrowserTab(urlString: String?, relativePath: String? = nil)
        -> RightPanelTab
    {
        let tab = RightPanelTab.browser(urlString: urlString, relativePath: relativePath)
        if !tabs.contains(where: { $0.id == tab.id }) {
            tabs.append(tab)
            tabs = Self.normalizedTabs(tabs)
        }
        selectedTabID = tab.id
        return tab
    }

    /// Updates the URL of the browser tab with the given id, reselecting it after normalization.
    public mutating func updateBrowserTab(id tabID: String, urlString: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID && $0.kind == .browser }) else {
            return
        }
        let preservedID = tabs[index].relativePath == nil ? tabID : nil
        tabs[index] = RightPanelTab.browser(
            urlString: urlString,
            relativePath: nil,
            id: preservedID
        )
        selectedTabID = tabs[index].id
        tabs = Self.normalizedTabs(tabs)
    }

    /// Closes the closable tab with the given id, choosing a new selection if needed,
    /// and returns the removed tab (or `nil` if it was absent or not closable).
    @discardableResult
    public mutating func closeTab(id tabID: String) -> RightPanelTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
            tabs[index].isClosable
        else {
            return nil
        }
        let removedTab = tabs.remove(at: index)
        tabs = Self.normalizedTabs(tabs)
        if selectedTabID == removedTab.id {
            selectedTabID = fallbackSelection(afterClosing: removedTab, at: index)
        }
        return removedTab
    }

    /// Returns the tabs reordered into their canonical layout (Files, browser tabs, Git, nvim tabs),
    /// deduplicated and with the default browser and nvim tabs always present.
    public static func normalizedTabs(_ tabs: [RightPanelTab]) -> [RightPanelTab] {
        var seenBrowser = Set<String>()
        var browserTabs: [RightPanelTab] = []
        for tab in tabs where tab.kind == .browser {
            guard !seenBrowser.contains(tab.id) else { continue }
            seenBrowser.insert(tab.id)
            browserTabs.append(tab)
        }

        if !browserTabs.contains(where: { $0.id == RightPanelTab.defaultBrowserID }) {
            browserTabs.insert(.defaultBrowser, at: 0)
        }

        var seen = Set<String>()
        var nvimTabs: [RightPanelTab] = []
        for tab in tabs where tab.kind == .nvim {
            guard !seen.contains(tab.id) else { continue }
            seen.insert(tab.id)
            nvimTabs.append(tab)
        }

        if !nvimTabs.contains(where: { $0.id == RightPanelTab.defaultNvimID }) {
            nvimTabs.insert(.defaultNvim, at: 0)
        }

        return [.files] + browserTabs + [.git] + nvimTabs
    }

    private func fallbackSelection(afterClosing closedTab: RightPanelTab, at closedIndex: Int)
        -> String
    {
        if let nextSameKind = tabs.dropFirst(closedIndex).first(where: {
            $0.kind == closedTab.kind
        }) {
            return nextSameKind.id
        }
        if let previousSameKind = tabs.prefix(closedIndex).last(where: {
            $0.kind == closedTab.kind
        }) {
            return previousSameKind.id
        }
        if tabs.contains(where: { $0.id == closedTab.kind.defaultTabID }) {
            return closedTab.kind.defaultTabID
        }
        return RightPanelTab.filesID
    }
}

extension RightPanelMode {
    var defaultTabID: String {
        switch self {
        case .files:
            RightPanelTab.filesID
        case .browser:
            RightPanelTab.defaultBrowserID
        case .git:
            RightPanelTab.gitID
        case .nvim:
            RightPanelTab.defaultNvimID
        }
    }
}

extension RightPanelTabKind {
    var defaultTabID: String {
        switch self {
        case .files:
            RightPanelTab.filesID
        case .browser:
            RightPanelTab.defaultBrowserID
        case .git:
            RightPanelTab.gitID
        case .nvim:
            RightPanelTab.defaultNvimID
        }
    }

    fileprivate var mode: RightPanelMode {
        switch self {
        case .files:
            .files
        case .browser:
            .browser
        case .git:
            .git
        case .nvim:
            .nvim
        }
    }
}
