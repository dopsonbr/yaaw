import YAAWKit
import AppKit
import Foundation

@MainActor
final class ExternalOpenWorkspace {
    private let workspace: NSWorkspace
    private let fileManager: FileManager

    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func availableTools(settings: ExternalOpenSettings) -> [ExternalOpenToolID] {
        ExternalOpenToolResolver.availableTools(
            settings: settings,
            detectedTools: detectedTools()
        )
    }

    func defaultTool(settings: ExternalOpenSettings) -> ExternalOpenToolID? {
        ExternalOpenToolResolver.defaultTool(
            settings: settings,
            detectedTools: detectedTools()
        )
    }

    func defaultEditorTool(settings: ExternalOpenSettings) -> ExternalOpenToolID? {
        ExternalOpenToolResolver.defaultEditorTool(
            settings: settings,
            detectedTools: detectedTools()
        )
    }

    func icon(for tool: ExternalOpenToolID) -> NSImage? {
        guard let applicationURL = applicationURL(for: tool) else { return nil }
        let icon = workspace.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    @discardableResult
    func open(target: ExternalOpenTarget, with tool: ExternalOpenToolID) -> Bool {
        if target.shouldRevealInFinder(for: tool) {
            workspace.activateFileViewerSelecting([target.url])
            return true
        }

        let launchURL = target.launchURL(for: tool)
        guard tool != .finder else {
            return workspace.open(launchURL)
        }
        guard let applicationURL = applicationURL(for: tool) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        workspace.open([launchURL], withApplicationAt: applicationURL, configuration: configuration)
        return true
    }

    private func detectedTools() -> Set<ExternalOpenToolID> {
        Set(ExternalOpenToolID.allCases.filter { isAvailable($0) })
    }

    private func isAvailable(_ tool: ExternalOpenToolID) -> Bool {
        tool == .finder || applicationURL(for: tool) != nil
    }

    private func applicationURL(for tool: ExternalOpenToolID) -> URL? {
        if let bundleIdentifier = tool.primaryBundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        for bundleIdentifier in tool.alternateBundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }
        return tool.applicationNames.lazy.compactMap(applicationURL(named:)).first
    }

    private func applicationURL(named applicationName: String) -> URL? {
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        for root in searchRoots {
            let candidate = root.appendingPathComponent(applicationName, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

private extension ExternalOpenToolID {
    var primaryBundleIdentifier: String? {
        switch self {
        case .vscode:
            return "com.microsoft.VSCode"
        case .vscodeInsiders:
            return "com.microsoft.VSCodeInsiders"
        case .sublimeText:
            return "com.sublimetext.4"
        case .zed:
            return "dev.zed.Zed"
        case .finder:
            return "com.apple.finder"
        case .terminal:
            return "com.apple.Terminal"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .xcode:
            return "com.apple.dt.Xcode"
        case .webstorm:
            return "com.jetbrains.WebStorm"
        }
    }

    var alternateBundleIdentifiers: [String] {
        switch self {
        case .sublimeText:
            return ["com.sublimetext.3"]
        default:
            return []
        }
    }

    var applicationNames: [String] {
        switch self {
        case .vscode:
            return ["Visual Studio Code.app"]
        case .vscodeInsiders:
            return ["Visual Studio Code - Insiders.app"]
        case .sublimeText:
            return ["Sublime Text.app"]
        case .zed:
            return ["Zed.app"]
        case .finder:
            return ["Finder.app"]
        case .terminal:
            return ["Terminal.app"]
        case .ghostty:
            return ["Ghostty.app"]
        case .xcode:
            return ["Xcode.app"]
        case .webstorm:
            return ["WebStorm.app"]
        }
    }
}
