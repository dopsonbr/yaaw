import Foundation

public enum RightPanelTabKind: String, Equatable, Sendable {
    case files
    case browser
    case git
    case nvim
}

public struct RightPanelTab: Identifiable, Equatable, Sendable {
    public static let filesID = "files"
    public static let defaultBrowserID = "browser"
    public static let gitID = "git"
    public static let defaultNvimID = "nvim"

    public var id: String
    public var kind: RightPanelTabKind
    public var title: String
    public var relativePath: String?
    public var urlString: String?

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

    public static let files = RightPanelTab(id: filesID, kind: .files, title: "Files")
    public static let defaultBrowser = RightPanelTab(
        id: defaultBrowserID, kind: .browser, title: "Browser")
    public static let git = RightPanelTab(id: gitID, kind: .git, title: "Git")
    public static let defaultNvim = RightPanelTab(id: defaultNvimID, kind: .nvim, title: "nvim")

    public var isClosable: Bool {
        switch id {
        case Self.filesID, Self.defaultBrowserID, Self.gitID, Self.defaultNvimID:
            false
        default:
            kind == .browser || kind == .nvim
        }
    }

    public static func nvim(relativePath: String) -> RightPanelTab {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(relativePath)
        return RightPanelTab(
            id: nvimTabID(relativePath: normalizedPath),
            kind: .nvim,
            title: URL(fileURLWithPath: normalizedPath).lastPathComponent,
            relativePath: normalizedPath
        )
    }

    public static func nvimTabID(relativePath: String) -> String {
        "nvim:\(FilePathNormalizer.normalizedRelativePath(relativePath))"
    }

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

public struct RightPanelState: Equatable, Sendable {
    public var tabs: [RightPanelTab]
    public var selectedTabID: String

    public init(
        tabs: [RightPanelTab] = RightPanelState.defaultTabs,
        selectedTabID: String = RightPanelTab.filesID
    ) {
        self.tabs = Self.normalizedTabs(tabs)
        self.selectedTabID =
            self.tabs.contains { $0.id == selectedTabID }
            ? selectedTabID
            : RightPanelTab.filesID
    }

    public static let defaultTabs: [RightPanelTab] = [
        .files,
        .defaultBrowser,
        .git,
        .defaultNvim,
    ]

    public static func defaultState(selectedMode: RightPanelMode = .files) -> RightPanelState {
        RightPanelState(selectedTabID: selectedMode.defaultTabID)
    }

    public static func restoredState(tabs: [RightPanelTab], selectedTabID: String)
        -> RightPanelState
    {
        let selectedKind = tabs.first { $0.id == selectedTabID }?.kind
        let selectedMode = selectedKind?.mode ?? .files
        return RightPanelState.defaultState(selectedMode: selectedMode)
    }

    public var persistenceSnapshot: RightPanelState {
        RightPanelState.defaultState(selectedMode: selectedMode)
    }

    public var selectedTab: RightPanelTab {
        tabs.first { $0.id == selectedTabID } ?? .files
    }

    public var selectedMode: RightPanelMode {
        selectedTab.kind.mode
    }

    public mutating func selectMode(_ mode: RightPanelMode) {
        selectedTabID = mode.defaultTabID
    }

    public mutating func selectTab(id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    public mutating func openNvimTab(relativePath: String) -> RightPanelTab {
        let tab = RightPanelTab.nvim(relativePath: relativePath)
        if !tabs.contains(where: { $0.id == tab.id }) {
            tabs.append(tab)
            tabs = Self.normalizedTabs(tabs)
        }
        selectedTabID = tab.id
        return tab
    }

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
