import XCTest
@testable import YAAWKit

final class IconSystemTests: XCTestCase {
    func testFileIconResolverPrefersExactFilenameBeforeExtension() {
        let resolver = FileIconResolver(pack: .material)

        let packageSwift = resolver.icon(
            for: FileBrowserEntry(relativePath: "Package.swift", isDirectory: false)
        )
        let packageJSON = resolver.icon(
            for: FileBrowserEntry(relativePath: "package.json", isDirectory: false)
        )
        let readme = resolver.icon(
            for: FileBrowserEntry(relativePath: "docs/README.md", isDirectory: false)
        )

        XCTAssertEqual(packageSwift.bundledAssetID, "material-file-icons/swift")
        XCTAssertEqual(packageJSON.bundledAssetID, "material-file-icons/package")
        XCTAssertEqual(readme.bundledAssetID, "material-file-icons/markdown")
    }

    func testFileIconResolverUsesCompoundExtensionsBeforeExtensions() {
        let resolver = FileIconResolver(pack: .material)

        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "src/App.test.ts", isDirectory: false)).bundledAssetID,
            "material-file-icons/typescript"
        )
        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "src/types.d.ts", isDirectory: false)).bundledAssetID,
            "material-file-icons/typescript"
        )
        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "src/App.module.css", isDirectory: false)).bundledAssetID,
            "material-file-icons/css"
        )
    }

    func testFileIconResolverUsesExtensionFallback() {
        let resolver = FileIconResolver(pack: .material)

        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false)).bundledAssetID,
            "material-file-icons/swift"
        )
        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: ".github/workflows/build.yml", isDirectory: false)).bundledAssetID,
            "material-file-icons/yaml"
        )
    }

    func testFileIconResolverUsesFolderNamesAndOpenFolderFallback() {
        let resolver = FileIconResolver(pack: .material)

        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "src", isDirectory: true), isExpanded: false).bundledAssetID,
            "material-file-icons/src-folder"
        )
        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "Examples", isDirectory: true), isExpanded: true).bundledAssetID,
            "material-file-icons/open-folder"
        )
        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "Examples", isDirectory: true), isExpanded: false).bundledAssetID,
            "material-file-icons/folder"
        )
    }

    func testFileIconResolverUsesGenericFileFallback() {
        let resolver = FileIconResolver(pack: .material)

        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "unknown.blob", isDirectory: false)).bundledAssetID,
            "material-file-icons/file"
        )
    }

    func testFileIconResolverKeepsSelectedPackInAssetIDs() {
        let resolver = FileIconResolver(pack: .catppuccin)

        XCTAssertEqual(
            resolver.icon(for: FileBrowserEntry(relativePath: "src/main.swift", isDirectory: false)).bundledAssetID,
            "catppuccin-file-icons/swift"
        )
    }

    func testNativeIconRolesResolveToSystemSymbols() {
        XCTAssertEqual(IconRole.settings.icon.systemSymbolName, "gearshape")
        XCTAssertEqual(IconRole.moreActions.icon.systemSymbolName, "ellipsis")
        XCTAssertEqual(IconRole.rightPanelMode(.files).icon.systemSymbolName, "doc.on.doc")
        XCTAssertEqual(IconRole.rightPanelMode(.git).icon.systemSymbolName, "arrow.triangle.branch")
        XCTAssertEqual(IconRole.rightPanelMode(.nvim).icon.systemSymbolName, "square.and.pencil")
        XCTAssertEqual(IconRole.fileStateOverlay(.modified).icon.systemSymbolName, "circle.fill")
        XCTAssertEqual(IconRole.fileStateOverlay(.conflicted).icon.systemSymbolName, "exclamationmark.triangle.fill")
    }

    func testAgentCLIKindsExposeBrandIconResourceNamesAndFallbackSymbols() {
        XCTAssertEqual(AgentCLIKind.codex.brandIconResourceName, "agent-codex")
        XCTAssertEqual(AgentCLIKind.claude.brandIconResourceName, "agent-claude")
        XCTAssertEqual(AgentCLIKind.opencode.brandIconResourceName, "agent-opencode")
        XCTAssertEqual(AgentCLIKind.copilot.brandIconResourceName, "agent-copilot")

        XCTAssertEqual(AgentCLIKind.claude.brandIconResourceExtensions.first, "png")
        XCTAssertEqual(AgentCLIKind.opencode.brandIconResourceExtensions.first, "png")
        XCTAssertEqual(AgentCLIKind.codex.brandIconResourceExtensions.first, "svg")
        XCTAssertEqual(AgentCLIKind.copilot.brandIconResourceExtensions.first, "svg")
        XCTAssertFalse(AgentCLIKind.allCases.map(\.fallbackSystemSymbolName).contains(""))
    }
}

private extension AppIcon {
    var bundledAssetID: String? {
        if case .bundledAsset(let asset) = self {
            return asset.id
        }
        return nil
    }
}
