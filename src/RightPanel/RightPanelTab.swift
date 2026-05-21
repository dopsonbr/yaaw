import Foundation

public enum RightPanelTabKind: String, Equatable, Sendable {
    case files
    case git
    case nvim
}

public struct RightPanelTab: Identifiable, Equatable, Sendable {
    public static let filesID = "files"
    public static let gitID = "git"
    public static let defaultNvimID = "nvim"

    public var id: String
    public var kind: RightPanelTabKind
    public var title: String
    public var relativePath: String?

    public init(
        id: String,
        kind: RightPanelTabKind,
        title: String,
        relativePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.relativePath = relativePath
    }

    public static let files = RightPanelTab(id: filesID, kind: .files, title: "Files")
    public static let git = RightPanelTab(id: gitID, kind: .git, title: "Git")
    public static let defaultNvim = RightPanelTab(id: defaultNvimID, kind: .nvim, title: "nvim")

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
}

public struct RightPanelState: Equatable, Sendable {
    public var tabs: [RightPanelTab]
    public var selectedTabID: String

    public init(tabs: [RightPanelTab] = RightPanelState.defaultTabs, selectedTabID: String = RightPanelTab.filesID) {
        self.tabs = Self.normalizedTabs(tabs)
        self.selectedTabID = self.tabs.contains { $0.id == selectedTabID }
            ? selectedTabID
            : RightPanelTab.filesID
    }

    public static let defaultTabs: [RightPanelTab] = [
        .files,
        .git,
        .defaultNvim
    ]

    public static func defaultState(selectedMode: RightPanelMode = .files) -> RightPanelState {
        RightPanelState(selectedTabID: selectedMode.defaultTabID)
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

    public static func normalizedTabs(_ tabs: [RightPanelTab]) -> [RightPanelTab] {
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

        return [.files, .git] + nvimTabs
    }
}

extension RightPanelMode {
    var defaultTabID: String {
        switch self {
        case .files:
            RightPanelTab.filesID
        case .git:
            RightPanelTab.gitID
        case .nvim:
            RightPanelTab.defaultNvimID
        }
    }
}

private extension RightPanelTabKind {
    var mode: RightPanelMode {
        switch self {
        case .files:
            .files
        case .git:
            .git
        case .nvim:
            .nvim
        }
    }
}
