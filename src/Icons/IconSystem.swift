import Foundation

public enum AppIcon: Equatable, Sendable {
    case systemSymbol(String)
    case bundledAsset(BundledIconAsset)

    public var systemSymbolName: String {
        switch self {
        case .systemSymbol(let name):
            name
        case .bundledAsset(let asset):
            asset.systemSymbolName
        }
    }

    public var draculaRole: DraculaRole? {
        switch self {
        case .systemSymbol:
            nil
        case .bundledAsset(let asset):
            asset.draculaRole
        }
    }
}

public struct BundledIconAsset: Equatable, Sendable {
    public let id: String
    public let pack: FileIconPack
    public let systemSymbolName: String
    public let draculaRole: DraculaRole

    public init(id: String, pack: FileIconPack, systemSymbolName: String, draculaRole: DraculaRole)
    {
        self.id = id
        self.pack = pack
        self.systemSymbolName = systemSymbolName
        self.draculaRole = draculaRole
    }
}

public enum IconRole: Equatable, Sendable {
    case sidebar
    case rightSidebar
    case navigateBack
    case navigateForward
    case settings
    case close
    case openDocument
    case reload
    case installUpdate
    case newProject
    case disclosureExpanded
    case disclosureCollapsed
    case pin
    case unpin
    case pinned
    case moveUp
    case moveDown
    case newThread
    case archive
    case unarchive
    case moreActions
    case add
    case warning
    case bottomTerminal
    case rightPanelMode(RightPanelMode)
    case fileStateOverlay(FileStateOverlay)

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
            .systemSymbol("text.badge.plus")
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

public enum FileStateOverlay: String, CaseIterable, Equatable, Identifiable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case ignored
    case untracked
    case conflicted
    case indexingPending
    case indexingFailed
    case externalToolUnavailable

    public var id: String { rawValue }

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

public enum FileIconPack: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case material = "material-file-icons"
    case catppuccin = "catppuccin-file-icons"

    public var id: String { rawValue }

    public static let fallback: FileIconPack = .material
}

public struct FileIconManifestEntry: Equatable, Sendable {
    public let assetID: String
    public let pack: FileIconPack
    public let licenseID: String
    public let exactFileNames: Set<String>
    public let compoundExtensions: Set<String>
    public let extensions: Set<String>
    public let folderNames: Set<String>
    public let systemSymbolName: String
    public let draculaRole: DraculaRole

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

    public var asset: BundledIconAsset {
        BundledIconAsset(
            id: assetID,
            pack: pack,
            systemSymbolName: systemSymbolName,
            draculaRole: draculaRole
        )
    }
}

public struct FileIconManifest: Equatable, Sendable {
    public let pack: FileIconPack
    public let sourceName: String
    public let licenseID: String
    public let entries: [FileIconManifestEntry]

    public init(
        pack: FileIconPack, sourceName: String, licenseID: String, entries: [FileIconManifestEntry]
    ) {
        self.pack = pack
        self.sourceName = sourceName
        self.licenseID = licenseID
        self.entries = entries
    }

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

public struct FileIconResolver: Equatable, Sendable {
    public let pack: FileIconPack
    private let manifest: FileIconManifest

    public init(pack: FileIconPack = .fallback) {
        self.pack = pack
        self.manifest = FileIconManifest.manifest(for: pack)
    }

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
