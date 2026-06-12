import Foundation

/// A resolved icon, either an SF Symbol or a bundled file-icon asset.
public enum AppIcon: Equatable, Sendable {
    /// An SF Symbol identified by its system symbol name.
    case systemSymbol(String)
    /// A bundled file-icon asset from one of the icon packs.
    case bundledAsset(BundledIconAsset)

    /// The SF Symbol name used to render this icon.
    public var systemSymbolName: String {
        switch self {
        case .systemSymbol(let name):
            name
        case .bundledAsset(let asset):
            asset.systemSymbolName
        }
    }

    /// The theme role tint for this icon, or `nil` for plain system symbols.
    public var draculaRole: DraculaRole? {
        switch self {
        case .systemSymbol:
            nil
        case .bundledAsset(let asset):
            asset.draculaRole
        }
    }
}

/// A file-icon asset drawn from an icon pack, with its symbol and tint role.
public struct BundledIconAsset: Equatable, Sendable {
    /// The asset identifier, namespaced by pack.
    public let id: String
    /// The icon pack this asset belongs to.
    public let pack: FileIconPack
    /// The SF Symbol name used to render the asset.
    public let systemSymbolName: String
    /// The theme role used to tint the asset.
    public let draculaRole: DraculaRole

    /// Creates a bundled icon asset.
    public init(id: String, pack: FileIconPack, systemSymbolName: String, draculaRole: DraculaRole)
    {
        self.id = id
        self.pack = pack
        self.systemSymbolName = systemSymbolName
        self.draculaRole = draculaRole
    }
}

/// A semantic UI icon role that maps to a concrete `AppIcon`.
public enum IconRole: Equatable, Sendable {
    /// Toggle for the left sidebar.
    case sidebar
    /// Toggle for the right sidebar.
    case rightSidebar
    /// Navigate to the previous location.
    case navigateBack
    /// Navigate to the next location.
    case navigateForward
    /// Open the settings/preferences surface.
    case settings
    /// Close the current item or surface.
    case close
    /// Open a document.
    case openDocument
    /// Reload the current content.
    case reload
    /// Install a pending update.
    case installUpdate
    /// Create a new project.
    case newProject
    /// Disclosure indicator for an expanded item.
    case disclosureExpanded
    /// Disclosure indicator for a collapsed item.
    case disclosureCollapsed
    /// Pin an item.
    case pin
    /// Unpin an item.
    case unpin
    /// Indicator for an already-pinned item.
    case pinned
    /// Move an item up in its ordering.
    case moveUp
    /// Move an item down in its ordering.
    case moveDown
    /// Create a new thread.
    case newThread
    /// Archive an item.
    case archive
    /// Restore an archived item.
    case unarchive
    /// Reveal additional actions.
    case moreActions
    /// Add a new item.
    case add
    /// A warning indicator.
    case warning
    /// Toggle for the bottom terminal.
    case bottomTerminal
    /// Swap between workspaces.
    case workspaceSwap
    /// Icon for a given right-panel mode.
    case rightPanelMode(RightPanelMode)
    /// Overlay badge for a file's git/index state.
    case fileStateOverlay(FileStateOverlay)

    /// The concrete icon that renders this role.
    public var icon: AppIcon {
        switch self {
        case .sidebar:
            .systemSymbol("sidebar.left")
        case .rightSidebar:
            .systemSymbol("sidebar.right")
        case .navigateBack:
            .systemSymbol("chevron.left")
        case .navigateForward:
            .systemSymbol("chevron.right")
        case .settings:
            .systemSymbol("gearshape")
        case .close:
            .systemSymbol("xmark")
        case .openDocument:
            .systemSymbol("doc.text")
        case .reload:
            .systemSymbol("arrow.clockwise")
        case .installUpdate:
            .systemSymbol("arrow.down.circle")
        case .newProject:
            .systemSymbol("folder.badge.plus")
        case .disclosureExpanded:
            .systemSymbol("chevron.down")
        case .disclosureCollapsed:
            .systemSymbol("chevron.right")
        case .pin:
            .systemSymbol("pin")
        case .unpin:
            .systemSymbol("pin.slash")
        case .pinned:
            .systemSymbol("pin.fill")
        case .moveUp:
            .systemSymbol("arrow.up")
        case .moveDown:
            .systemSymbol("arrow.down")
        case .newThread:
            .systemSymbol("plus")
        case .archive:
            .systemSymbol("archivebox")
        case .unarchive:
            .systemSymbol("arrow.uturn.backward")
        case .moreActions:
            .systemSymbol("ellipsis")
        case .add:
            .systemSymbol("plus")
        case .warning:
            .systemSymbol("exclamationmark.triangle")
        case .bottomTerminal:
            .systemSymbol("terminal")
        case .workspaceSwap:
            .systemSymbol("arrow.left.arrow.right")
        case .rightPanelMode(let mode):
            switch mode {
            case .files:
                .systemSymbol("doc.on.doc")
            case .browser:
                .systemSymbol("globe")
            case .git:
                .systemSymbol("arrow.triangle.branch")
            case .nvim:
                .systemSymbol("square.and.pencil")
            }
        case .fileStateOverlay(let overlay):
            .systemSymbol(overlay.systemSymbolName)
        }
    }
}

/// A badge overlaying a file icon to convey its git or indexing state.
public enum FileStateOverlay: String, CaseIterable, Equatable, Identifiable, Sendable {
    /// The file has uncommitted modifications.
    case modified
    /// The file is newly added to the index.
    case added
    /// The file has been deleted.
    case deleted
    /// The file has been renamed.
    case renamed
    /// The file is ignored by git.
    case ignored
    /// The file is untracked by git.
    case untracked
    /// The file has a merge conflict.
    case conflicted
    /// The file is awaiting indexing.
    case indexingPending
    /// Indexing the file failed.
    case indexingFailed
    /// A required external tool is unavailable.
    case externalToolUnavailable

    /// The stable identifier (the raw value).
    public var id: String { rawValue }

    /// The SF Symbol name used to render this overlay badge.
    public var systemSymbolName: String {
        switch self {
        case .modified:
            "circle.fill"
        case .added:
            "plus.circle.fill"
        case .deleted:
            "minus.circle.fill"
        case .renamed:
            "arrow.triangle.2.circlepath"
        case .ignored:
            "eye.slash"
        case .untracked:
            "questionmark.circle"
        case .conflicted:
            "exclamationmark.triangle.fill"
        case .indexingPending:
            "clock"
        case .indexingFailed:
            "xmark.octagon.fill"
        case .externalToolUnavailable:
            "wrench.and.screwdriver"
        }
    }
}

/// A selectable file-icon pack.
public enum FileIconPack: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    /// The Material file icon theme.
    case material = "material-file-icons"
    /// The Catppuccin icon theme.
    case catppuccin = "catppuccin-file-icons"

    /// The stable identifier (the raw value).
    public var id: String { rawValue }

    /// The pack used when none is selected.
    public static let fallback: FileIconPack = .material
}

/// One manifest rule mapping file/folder name patterns to an icon asset.
public struct FileIconManifestEntry: Equatable, Sendable {
    /// The asset identifier, namespaced by pack.
    public let assetID: String
    /// The icon pack this entry belongs to.
    public let pack: FileIconPack
    /// The license identifier for the asset's source.
    public let licenseID: String
    /// Lowercased file names matched exactly.
    public let exactFileNames: Set<String>
    /// Lowercased compound extensions (for example `test.ts`) matched as suffixes.
    public let compoundExtensions: Set<String>
    /// Lowercased single file extensions matched against the path extension.
    public let extensions: Set<String>
    /// Lowercased folder names matched exactly.
    public let folderNames: Set<String>
    /// The SF Symbol name used to render the asset.
    public let systemSymbolName: String
    /// The theme role used to tint the asset.
    public let draculaRole: DraculaRole

    /// Creates a manifest entry, lowercasing all name and extension patterns.
    public init(
        assetID: String,
        pack: FileIconPack,
        licenseID: String,
        exactFileNames: Set<String> = [],
        compoundExtensions: Set<String> = [],
        extensions: Set<String> = [],
        folderNames: Set<String> = [],
        systemSymbolName: String,
        draculaRole: DraculaRole
    ) {
        self.assetID = assetID
        self.pack = pack
        self.licenseID = licenseID
        self.exactFileNames = Set(exactFileNames.map { $0.lowercased() })
        self.compoundExtensions = Set(compoundExtensions.map { $0.lowercased() })
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.folderNames = Set(folderNames.map { $0.lowercased() })
        self.systemSymbolName = systemSymbolName
        self.draculaRole = draculaRole
    }

    /// The bundled icon asset described by this entry.
    public var asset: BundledIconAsset {
        BundledIconAsset(
            id: assetID,
            pack: pack,
            systemSymbolName: systemSymbolName,
            draculaRole: draculaRole
        )
    }
}

/// The full set of icon-mapping rules for a single icon pack.
public struct FileIconManifest: Equatable, Sendable {
    /// The icon pack this manifest describes.
    public let pack: FileIconPack
    /// The human-readable name of the pack's source.
    public let sourceName: String
    /// The license identifier for the pack's source.
    public let licenseID: String
    /// The ordered icon-mapping entries; earlier entries take precedence.
    public let entries: [FileIconManifestEntry]

    /// Creates a manifest from its pack metadata and entries.
    public init(
        pack: FileIconPack, sourceName: String, licenseID: String, entries: [FileIconManifestEntry]
    ) {
        self.pack = pack
        self.sourceName = sourceName
        self.licenseID = licenseID
        self.entries = entries
    }

    /// Returns the built-in manifest for the given icon pack.
    public static func manifest(for pack: FileIconPack) -> FileIconManifest {
        switch pack {
        case .material:
            makeManifest(pack: .material, sourceName: "Material Icon Theme", licenseID: "MIT")
        case .catppuccin:
            makeManifest(pack: .catppuccin, sourceName: "Catppuccin Icons", licenseID: "MIT")
        }
    }

    private static func makeManifest(pack: FileIconPack, sourceName: String, licenseID: String)
        -> FileIconManifest
    {
        FileIconManifest(
            pack: pack,
            sourceName: sourceName,
            licenseID: licenseID,
            entries: [
                entry(
                    "swift", pack, licenseID, exact: ["package.swift"], ext: ["swift"],
                    symbol: "swift", role: .orange),
                entry(
                    "typescript", pack, licenseID,
                    compound: ["test.ts", "spec.ts", "config.ts", "d.ts"], ext: ["ts"],
                    symbol: "chevron.left.forwardslash.chevron.right", role: .cyan),
                entry(
                    "typescript-react", pack, licenseID, compound: ["test.tsx", "spec.tsx"],
                    ext: ["tsx"], symbol: "chevron.left.forwardslash.chevron.right", role: .cyan),
                entry(
                    "javascript", pack, licenseID, compound: ["test.js", "spec.js", "config.js"],
                    ext: ["js", "mjs", "cjs"], symbol: "curlybraces", role: .yellow),
                entry(
                    "json", pack, licenseID, exact: ["tsconfig.json"], ext: ["json"],
                    symbol: "curlybraces.square", role: .yellow),
                entry(
                    "css", pack, licenseID, compound: ["module.css"], ext: ["css"],
                    symbol: "paintpalette", role: .pink),
                entry(
                    "markdown", pack, licenseID, exact: ["readme", "readme.md", "agents.md"],
                    ext: ["md", "markdown"], symbol: "doc.richtext", role: .purple),
                entry(
                    "yaml", pack, licenseID, ext: ["yml", "yaml"], symbol: "slider.horizontal.3",
                    role: .pink),
                entry(
                    "shell", pack, licenseID, ext: ["sh", "bash", "zsh"], symbol: "terminal",
                    role: .green),
                entry(
                    "docker", pack, licenseID,
                    exact: ["dockerfile", "docker-compose.yml", "docker-compose.yaml"],
                    symbol: "shippingbox", role: .cyan),
                entry(
                    "git", pack, licenseID, exact: [".gitignore", ".gitattributes", ".gitmodules"],
                    folder: [".git", ".github"], symbol: "arrow.triangle.branch", role: .orange),
                entry(
                    "package", pack, licenseID,
                    exact: [
                        "package.json", "package-lock.json", "bun.lockb", "pnpm-lock.yaml",
                        "yarn.lock",
                    ], symbol: "cube.box", role: .yellow),
                entry(
                    "docs-folder", pack, licenseID, folder: ["docs", "documentation"],
                    symbol: "folder.badge.gearshape", role: .purple),
                entry(
                    "src-folder", pack, licenseID, folder: ["src", "source", "sources"],
                    symbol: "folder.badge.gearshape", role: .cyan),
                entry(
                    "tests-folder", pack, licenseID, folder: ["test", "tests", "__tests__"],
                    symbol: "folder.badge.questionmark", role: .green),
                entry(
                    "assets-folder", pack, licenseID, folder: ["asset", "assets", "resources"],
                    symbol: "folder.badge.plus", role: .pink),
                entry(
                    "vscode-folder", pack, licenseID, folder: [".vscode"],
                    symbol: "folder.badge.gearshape", role: .cyan),
                entry("open-folder", pack, licenseID, symbol: "folder.fill", role: .cyan),
                entry("folder", pack, licenseID, symbol: "folder", role: .cyan),
                entry("file", pack, licenseID, symbol: "doc.text", role: .foreground),
            ]
        )
    }

    private static func entry(
        _ id: String,
        _ pack: FileIconPack,
        _ licenseID: String,
        exact: Set<String> = [],
        compound: Set<String> = [],
        ext: Set<String> = [],
        folder: Set<String> = [],
        symbol: String,
        role: DraculaRole
    ) -> FileIconManifestEntry {
        FileIconManifestEntry(
            assetID: "\(pack.rawValue)/\(id)",
            pack: pack,
            licenseID: licenseID,
            exactFileNames: exact,
            compoundExtensions: compound,
            extensions: ext,
            folderNames: folder,
            systemSymbolName: symbol,
            draculaRole: role
        )
    }
}

/// Resolves the icon for a file-browser entry using a pack's manifest.
public struct FileIconResolver: Equatable, Sendable {
    /// The icon pack used to resolve icons.
    public let pack: FileIconPack
    private let manifest: FileIconManifest

    /// Creates a resolver backed by the given icon pack.
    public init(pack: FileIconPack = .fallback) {
        self.pack = pack
        self.manifest = FileIconManifest.manifest(for: pack)
    }

    /// Resolves the icon for a file-browser entry, using the expanded folder
    /// variant when `isExpanded` is `true`.
    public func icon(for entry: FileBrowserEntry, isExpanded: Bool = false) -> AppIcon {
        let normalizedPath = FilePathNormalizer.normalizedRelativePath(entry.relativePath)
            .lowercased()
        let fileName = normalizedPath.split(separator: "/").last.map(String.init) ?? normalizedPath

        if entry.isDirectory {
            if let match = manifest.entries.first(where: { $0.folderNames.contains(fileName) }) {
                return .bundledAsset(match.asset)
            }
            return fallbackAsset(isExpanded ? "open-folder" : "folder")
        }

        if let match = manifest.entries.first(where: { $0.exactFileNames.contains(fileName) }) {
            return .bundledAsset(match.asset)
        }

        if let match = manifest.entries.first(where: { entry in
            entry.compoundExtensions.contains { fileName.hasSuffix(".\($0)") || fileName == $0 }
        }) {
            return .bundledAsset(match.asset)
        }

        let pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if let match = manifest.entries.first(where: { $0.extensions.contains(pathExtension) }) {
            return .bundledAsset(match.asset)
        }

        return fallbackAsset("file")
    }

    private func fallbackAsset(_ id: String) -> AppIcon {
        guard let match = manifest.entries.first(where: { $0.assetID == "\(pack.rawValue)/\(id)" })
        else {
            return .systemSymbol(id == "file" ? "doc.text" : "folder")
        }
        return .bundledAsset(match.asset)
    }
}
