import Foundation

/// How a CLI's resume invocation is assembled from a session identifier.
public enum ResumeTemplate: Codable, Equatable, Sendable {
    /// Positional prefix then the id: `["resume"]` → `resume <id>` (codex).
    case positional(prefix: [String])
    /// Space-separated flag: `"--resume"` → `--resume <id>` (claude),
    /// `"--session"` → `--session <id>` (opencode).
    case flagSpaced(flag: String)
    /// Equals-joined flag: `"--resume"` → `--resume=<id>` (copilot).
    case flagEquals(flag: String)

    /// Builds the resume arguments for `sessionIdentity`.
    public func arguments(sessionIdentity: String) -> [String] {
        switch self {
        case .positional(let prefix):
            return prefix + [sessionIdentity]
        case .flagSpaced(let flag):
            return [flag, sessionIdentity]
        case .flagEquals(let flag):
            return ["\(flag)=\(sessionIdentity)"]
        }
    }
}

/// Whether (and how) a CLI accepts a session name at launch time.
public enum StartNameCapability: Codable, Equatable, Sendable {
    /// The CLI cannot be given a name at launch.
    case none
    /// The CLI takes the name via a flag: `"--name"` → `--name <name>`.
    case viaFlag(flag: String)
}

/// Whether (and how) a CLI can be renamed interactively after launch.
public enum RenameCapability: Codable, Equatable, Sendable {
    /// The CLI cannot be renamed.
    case none
    /// Rename via a startup-input command, e.g. `"/rename {name}\n"`.
    case viaStartupInput(command: String)
    /// Like ``viaStartupInput(command:)`` but only valid once the session has a
    /// stored identity (i.e. it has been resumed at least once).
    case viaStartupInputIfResumed(command: String)
}

/// On-disk format of a catalog file.
public enum CatalogFileFormat: String, Codable, Equatable, Sendable {
    /// One JSON object per line.
    case jsonl
    /// A single JSON document.
    case json
}

/// A catalog file (or glob) a CLI writes its sessions to.
public struct CatalogLocation: Codable, Equatable, Sendable {
    /// Base directory, tilde-expanded relative to the user's home.
    public var basePath: String
    /// File name or relative glob beneath ``basePath``. The token
    /// `{encoded-workdir}` is replaced with the reversibly-encoded working
    /// directory (claude project directories).
    public var pattern: String
    /// On-disk format of the matched files.
    public var fileFormat: CatalogFileFormat

    /// Creates a catalog location.
    public init(basePath: String, pattern: String, fileFormat: CatalogFileFormat) {
        self.basePath = basePath
        self.pattern = pattern
        self.fileFormat = fileFormat
    }
}

/// Which metadata field an output line-prefix pattern populates.
public enum OutputMetadataField: String, Codable, Equatable, Sendable {
    case sessionIdentity
    case displayName
    case title
}

/// A set of case-insensitive line prefixes that, when matched, yield a value for
/// ``OutputMetadataField``.
public struct OutputMetadataPattern: Codable, Equatable, Sendable {
    /// The field this pattern populates.
    public var field: OutputMetadataField
    /// Case-insensitive line prefixes that introduce the value.
    public var prefixes: [String]

    /// Creates an output-metadata pattern.
    public init(field: OutputMetadataField, prefixes: [String]) {
        self.field = field
        self.prefixes = prefixes
    }
}

/// A type-dependent top-level field extraction rule (claude).
///
/// When a catalog line's `typeKey` equals `whenType`, the display name is read
/// from `field` — but only from the line's own top level, never recursively.
public struct TypeDependentField: Codable, Equatable, Sendable {
    /// The value of the type key this rule applies to (e.g. `"custom-title"`).
    public var whenType: String
    /// The top-level field to read the name from (e.g. `"customTitle"`).
    public var field: String
    /// Lower priority wins only if no higher-priority rule matched first.
    public var precedence: Int

    /// Creates a type-dependent extraction rule.
    public init(whenType: String, field: String, precedence: Int) {
        self.whenType = whenType
        self.field = field
        self.precedence = precedence
    }
}

/// Rules for extracting a display name from a catalog whose lines are tagged by
/// a discriminating type key (claude's `custom-title` / `agent-name` / `summary`).
public struct CatalogMetadataRules: Codable, Equatable, Sendable {
    /// The key whose value selects which extraction rule applies (`"type"`).
    public var typeKey: String
    /// The ordered, precedence-ranked type-dependent fields.
    public var typeDependentFields: [TypeDependentField]

    /// Creates catalog metadata rules.
    public init(typeKey: String, typeDependentFields: [TypeDependentField]) {
        self.typeKey = typeKey
        self.typeDependentFields = typeDependentFields
    }
}

/// Where a CLI's permission presets come from.
public enum PermissionPresetSource: String, Codable, Equatable, Sendable {
    /// Use the hardcoded `AgentPermissionMode.builtInModes(for:)` set.
    case hardcoded
    /// Discover supported flags by scanning the CLI's `--help` output.
    case discoverable
    /// The CLI has no permission-mode support.
    case none
}

/// A declarative description of one agent CLI family: its invocation templates,
/// catalog locations, metadata-extraction patterns, and capabilities.
///
/// The four built-in instances live in `CLIManifest+Instances.swift`. Adding a
/// fifth CLI is a new manifest plus fixtures — no new adapter class.
public struct CLIManifest: Codable, Equatable, Sendable {
    /// The CLI family this manifest describes.
    public var kind: AgentCLIKind
    /// The default executable name (overridable per thread / per config).
    public var executableName: String

    /// How a resume invocation is assembled.
    public var resumeTemplate: ResumeTemplate
    /// Whether a name can be set at launch.
    public var startNameCapability: StartNameCapability
    /// Whether the session can be renamed interactively.
    public var renameCapability: RenameCapability
    /// Whether the terminal title is a reliable session-name source. `false`
    /// only for claude, which repurposes the title for transient tool activity.
    public var usesTerminalTitleAsSessionName: Bool

    /// Catalog files this CLI writes its sessions to (priority-ordered).
    public var catalogLocations: [CatalogLocation]
    /// Priority-ordered field names that hold the session identity.
    public var sessionIdentityKeys: [String]
    /// Priority-ordered field names that hold the display name.
    public var displayNameKeys: [String]
    /// Priority-ordered field names that hold the working directory.
    public var workingDirectoryKeys: [String]
    /// Priority-ordered field names that hold the last-updated timestamp.
    public var timestampKeys: [String]
    /// Type-dependent display-name extraction rules (claude only), if any.
    public var catalogMetadataRules: CatalogMetadataRules?
    /// If `true`, candidates without an explicit working directory are rejected
    /// (opencode, copilot); otherwise an unknown directory is allowed (codex,
    /// claude).
    public var directoryMatchingStrict: Bool

    /// Line-prefix patterns for scraping metadata from live CLI output.
    public var outputMetadataPatterns: [OutputMetadataPattern]

    /// Where this CLI's permission presets come from.
    public var permissionPresetSource: PermissionPresetSource

    /// Creates a manifest.
    public init(
        kind: AgentCLIKind,
        executableName: String,
        resumeTemplate: ResumeTemplate,
        startNameCapability: StartNameCapability,
        renameCapability: RenameCapability,
        usesTerminalTitleAsSessionName: Bool,
        catalogLocations: [CatalogLocation],
        sessionIdentityKeys: [String],
        displayNameKeys: [String],
        workingDirectoryKeys: [String],
        timestampKeys: [String],
        catalogMetadataRules: CatalogMetadataRules? = nil,
        directoryMatchingStrict: Bool,
        outputMetadataPatterns: [OutputMetadataPattern],
        permissionPresetSource: PermissionPresetSource
    ) {
        self.kind = kind
        self.executableName = executableName
        self.resumeTemplate = resumeTemplate
        self.startNameCapability = startNameCapability
        self.renameCapability = renameCapability
        self.usesTerminalTitleAsSessionName = usesTerminalTitleAsSessionName
        self.catalogLocations = catalogLocations
        self.sessionIdentityKeys = sessionIdentityKeys
        self.displayNameKeys = displayNameKeys
        self.workingDirectoryKeys = workingDirectoryKeys
        self.timestampKeys = timestampKeys
        self.catalogMetadataRules = catalogMetadataRules
        self.directoryMatchingStrict = directoryMatchingStrict
        self.outputMetadataPatterns = outputMetadataPatterns
        self.permissionPresetSource = permissionPresetSource
    }

    /// Whether a session name can be applied at launch (start-name capability).
    public var supportsStartName: Bool {
        if case .none = startNameCapability { return false }
        return true
    }

    /// Whether the session can be renamed interactively after launch.
    public var supportsInteractiveRename: Bool {
        if case .none = renameCapability { return false }
        return true
    }
}
