# Chunk 0.3 — Domain Model Port Specification

**Purpose:** This document catalogs the exact public contents and APIs of all domain model types that will be ported largely verbatim from the original YAAW codebase into the rewrite. These become the shared vocabulary all parallel chunks (A–E) build upon.

**Applicability:** Swift 6 strict concurrency `complete`; all types must compile cleanly without `@unchecked Sendable` escapes; any mutable static state, `NSLock`, or other serialization machinery must be identified and remediated.

---

## Source Files & Public Inventory

### 1. Projects & Threads Domain Model

#### `src/Projects/Project.swift`

**Public Types:**

```swift
public struct Project: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var rootDirectory: URL
    public var createdAt: Date
    public var lastOpenedAt: Date
    public var isPinned: Bool
    public var sortOrder: Int
    public var isArchived: Bool
    
    public init(
        id: UUID = UUID(),
        displayName: String,
        rootDirectory: URL,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        isPinned: Bool = false,
        sortOrder: Int = 0,
        isArchived: Bool = false
    )
}

public enum ProjectMoveDirection: Sendable {
    case up
    case down
}
```

**Conformances:** `Identifiable`, `Equatable`, `Sendable`; no `Codable` (persisted via SQLite).

**Concurrency Notes:** Fully immutable value type; no issues under strict concurrency.

---

#### `src/Threads/AgentCLIKind.swift`

**Public Types:**

```swift
public enum AgentCLIKind: String, CaseIterable, Identifiable, Equatable, Sendable, Codable {
    case codex
    case claude
    case opencode
    case copilot
    
    public var id: String
    public var displayName: String
    public var brandIconResourceName: String
    public var brandIconResourceExtensions: [String]
    public var fallbackSystemSymbolName: String
}
```

**Conformances:** `String`-backed enum with `CaseIterable`, `Identifiable`, `Equatable`, `Sendable`, `Codable`.

**Concurrency Notes:** Pure enum; no concurrency hazards.

---

#### `src/Threads/AgentThread.swift`

**Public Types:**

```swift
public struct AgentThread: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var projectID: UUID
    public var workingDirectory: URL
    public var agentCLI: AgentCLIKind
    public var launchOptions: AgentLaunchOptions
    public var sessionIdentity: String?
    public var canonicalSessionName: String?
    public var pendingSessionRename: String?
    public var createdAt: Date
    public var lastOpenedAt: Date
    public var isArchived: Bool
    public var isPinned: Bool
    
    public init(
        id: UUID = UUID(),
        displayName: String,
        projectID: UUID,
        workingDirectory: URL,
        agentCLI: AgentCLIKind = .codex,
        launchOptions: AgentLaunchOptions = AgentLaunchOptions(),
        sessionIdentity: String? = nil,
        canonicalSessionName: String? = nil,
        pendingSessionRename: String? = nil,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        isArchived: Bool = false,
        isPinned: Bool = false
    )
}
```

**Conformances:** `Identifiable`, `Equatable`, `Sendable`; no `Codable` (persisted via SQLite).

**Concurrency Notes:** Fully immutable; init calls `launchOptions.validated(for:)` and trims `pendingSessionRename`.

---

#### `src/Threads/AgentLaunchOptions.swift`

**Public Types:**

```swift
public struct AgentLaunchOptions: Codable, Equatable, Sendable {
    public static let defaultPermissionModeID = "default"
    
    public var executableName: String?
    public var permissionModeID: String?
    public var additionalArguments: [String]
    
    public init(
        executableName: String? = nil,
        permissionModeID: String? = nil,
        additionalArguments: [String] = []
    )
    
    public var isEmpty: Bool
    
    public func validated(
        for agentCLI: AgentCLIKind,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> AgentLaunchOptions
    
    public func permissionArguments(
        for agentCLI: AgentCLIKind,
        permissionModes: [AgentPermissionMode]? = nil
    ) -> [String]
    
    public static func parseAdditionalArguments(_ text: String) throws -> [String]
    public static func formatAdditionalArguments(_ arguments: [String]) -> String
}

public struct AgentPermissionMode: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var arguments: [String]
    
    public init(id: String, displayName: String, arguments: [String])
    
    public static func supportedModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode]
    public static func builtInModes(for agentCLI: AgentCLIKind) -> [AgentPermissionMode]
}

public enum AgentLaunchOptionsArgumentError: Error, Equatable, Sendable {
    case trailingEscape
    case unclosedQuote
}
```

**Conformances:** `Codable`, `Equatable`, `Sendable`.

**Concurrency Notes:** Pure value type; no mutable state.

**Key Algorithm (QuoteEscape Parsing):** Handles double/single quotes, backslash escapes, whitespace delimiters (lines 54–109). Port verbatim.

---

#### `src/Threads/ThreadActivity.swift`

**Public Types:**

```swift
public enum ThreadActivityStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case working
    case needsInput
    case complete
    case inactive
    
    public var cliValue: String
    public static func parse(_ value: String?) -> ThreadActivityStatus?
}

public enum ThreadActivitySource: String, Codable, Equatable, Sendable {
    case helper
    case terminalNotification
    case terminalLifecycle
}

public struct ThreadActivityState: Equatable, Sendable {
    public var threadID: UUID
    public var status: ThreadActivityStatus
    public var preview: String?
    public var isUnread: Bool
    public var title: String?
    public var body: String?
    public var source: ThreadActivitySource
    public var updatedAt: Date
    
    public init(
        threadID: UUID,
        status: ThreadActivityStatus = .inactive,
        preview: String? = nil,
        isUnread: Bool = false,
        title: String? = nil,
        body: String? = nil,
        source: ThreadActivitySource = .terminalLifecycle,
        updatedAt: Date = Date()
    )
    
    public func downgradedForLaunch() -> ThreadActivityState
}

public struct ThreadActivityEvent: Equatable, Sendable {
    public var threadID: UUID
    public var status: ThreadActivityStatus?
    public var title: String?
    public var body: String?
    public var source: ThreadActivitySource
    public var createdAt: Date
    
    public init(
        threadID: UUID,
        status: ThreadActivityStatus?,
        title: String?,
        body: String?,
        source: ThreadActivitySource,
        createdAt: Date = Date()
    )
    
    public static func helperEvents(from output: String) -> [ThreadActivityEvent]
}

public enum ThreadActivityText {
    public static let maximumPreviewLength = 240
    
    public static func sanitized(_ text: String?) -> String?
    public static func preview(title: String?, body: String?) -> String?
    public static func inferredStatus(title: String?, body: String?) -> ThreadActivityStatus?
    public static func inferredStatus(fromTerminalOutput output: String) -> ThreadActivityStatus?
}

public enum ThreadRelativeTimeFormatter {
    public static func shortElapsed(since date: Date, now: Date = Date()) -> String
}

public struct ThreadActivityNotification: Equatable, Sendable {
    public var threadID: UUID
    public var title: String
    public var subtitle: String
    public var body: String
    
    public init(threadID: UUID, title: String, subtitle: String, body: String)
}

public protocol ThreadActivityNotificationDispatching: AnyObject, Sendable {
    func dispatch(_ notification: ThreadActivityNotification)
}

public protocol ThreadActivityBadgeUpdating: AnyObject, Sendable {
    func updateUnreadThreadActivityCount(_ count: Int)
}

public final class NoopThreadActivityNotificationDispatcher: ThreadActivityNotificationDispatching
public final class NoopThreadActivityBadgeUpdater: ThreadActivityBadgeUpdating
```

**Conformances:** All enums/structs `Equatable` and `Sendable`; event parsing uses NDJSON with `JSONSerialization`.

**Concurrency Notes:** Pure value types and enums; protocols are `AnyObject & Sendable` (safe for class-based implementations).

**Key Constants:**
- `maximumPreviewLength = 240`
- ANSI escape stripping via three regex patterns (OSC 7, CSI, and other control sequences)
- Status inference via substring matching in sanitized/lowercased text

---

### 2. Layout & Right Panel State

#### `src/Layout/LayoutState.swift`

**Public Types:**

```swift
public struct LayoutState: Equatable, Sendable {
    public static let defaultSidebarWidth = 250.0
    public static let defaultRightPanelWidth = 360.0
    public static let defaultGlobalTerminalHeight = 140.0
    public static let minimumSidebarWidth = 180.0
    public static let maximumSidebarWidth = 520.0
    public static let minimumRightPanelWidth = 280.0
    public static let minimumMainWorkspaceWidth = 420.0
    public static let minimumGlobalTerminalHeight = 96.0
    public static let maximumGlobalTerminalHeight = 420.0
    
    public var sidebarWidth: Double
    public var rightPanelWidth: Double
    public var globalTerminalHeight: Double
    public var isSidebarCollapsed: Bool
    public var isRightPanelCollapsed: Bool
    public var isGlobalTerminalExpanded: Bool
    public var isWorkspaceSwapped: Bool
    
    public init(
        sidebarWidth: Double = defaultSidebarWidth,
        rightPanelWidth: Double = defaultRightPanelWidth,
        globalTerminalHeight: Double = defaultGlobalTerminalHeight,
        isSidebarCollapsed: Bool = false,
        isRightPanelCollapsed: Bool = false,
        isGlobalTerminalExpanded: Bool = false,
        isWorkspaceSwapped: Bool = false
    )
    
    public static var defaults: LayoutState
    public static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double
    public static func clampMinimum(_ value: Double, minimum: Double) -> Double
    public static func maximumGlobalTerminalHeight(for availableWindowHeight: Double?) -> Double
    public static func clampedGlobalTerminalHeight(
        _ value: Double,
        availableWindowHeight: Double? = nil
    ) -> Double
    
    public mutating func resetSidebarWidth()
    public mutating func resetRightPanelWidth()
    public mutating func resetGlobalTerminalHeight()
}
```

**Conformances:** `Equatable`, `Sendable`.

**Concurrency Notes:** Pure value type; clamping done in init.

---

#### `src/RightPanel/RightPanelMode.swift`

**Public Types:**

```swift
public enum RightPanelMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case files
    case browser
    case nvim
    case git
    
    public var id: String
    public var displayName: String
    public var next: RightPanelMode
    public var previous: RightPanelMode
}
```

**Conformances:** `String`-backed enum with `CaseIterable`, `Identifiable`, `Equatable`, `Sendable`.

---

#### `src/RightPanel/RightPanelTab.swift`

**Public Types:**

```swift
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
    )
    
    public static let files: RightPanelTab
    public static let defaultBrowser: RightPanelTab
    public static let git: RightPanelTab
    public static let defaultNvim: RightPanelTab
    
    public var isClosable: Bool
    
    public static func nvim(relativePath: String) -> RightPanelTab
    public static func nvimTabID(relativePath: String) -> String
    public static func browser(
        urlString: String?,
        relativePath: String? = nil,
        id: String? = nil
    ) -> RightPanelTab
    public static func browserTabID(urlString: String?, relativePath: String?) -> String
}

public struct RightPanelState: Equatable, Sendable {
    public var tabs: [RightPanelTab]
    public var selectedTabID: String
    
    public init(
        tabs: [RightPanelTab] = RightPanelState.defaultTabs,
        selectedTabID: String = RightPanelTab.filesID
    )
    
    public static let defaultTabs: [RightPanelTab]
    public static func defaultState(selectedMode: RightPanelMode = .files) -> RightPanelState
    public static func restoredState(tabs: [RightPanelTab], selectedTabID: String) -> RightPanelState
    
    public var persistenceSnapshot: RightPanelState
    public var selectedTab: RightPanelTab
    public var selectedMode: RightPanelMode
    
    public mutating func selectMode(_ mode: RightPanelMode)
    public mutating func selectTab(id: String)
    public mutating func openNvimTab(relativePath: String) -> RightPanelTab
    public mutating func openBrowserTab(
        urlString: String?,
        relativePath: String? = nil
    ) -> RightPanelTab
    public mutating func updateBrowserTab(id tabID: String, urlString: String?)
    public mutating func closeTab(id tabID: String) -> RightPanelTab?
    
    public static func normalizedTabs(_ tabs: [RightPanelTab]) -> [RightPanelTab]
}
```

**Conformances:** All `Equatable` and `Sendable`.

**Key Behaviors:**
- Path normalization via `FilePathNormalizer.normalizedRelativePath`
- Tab deduplication and normalization in `normalizedTabs()` (lines 226–252)
- Browser tab ID generation uses URL string or file path (lines 79–89)
- `persistenceSnapshot` returns only default tabs (drops custom browser/nvim tabs, preserving across relaunch as per plan row)

---

### 3. Theme, Icons, Fonts

#### `src/Theme/DraculaTheme.swift`

**Public Types (Large Enumeration):**

```swift
public enum ThemeRole: String, CaseIterable, Identifiable, Sendable {
    case background, currentLine, foreground, comment
    case cyan, green, orange, pink, purple, red, yellow
    public var id: String
}

public enum ThemeGroup: String, CaseIterable, Identifiable, Sendable {
    case light, dark, highContrast
    public var id: String
    public var displayName: String
}

public enum ThemePreferredColorScheme: String, Equatable, Sendable {
    case light, dark
}

public enum ThemeUIRole: String, CaseIterable, Identifiable, Sendable {
    case controlBackground, controlForeground, secondaryLabel
    case controlBorder, focusAccent
    public var id: String
}

public struct ThemeToken: Equatable, Sendable {
    public let role: ThemeRole
    public let hex: String
    public init(role: ThemeRole, hex: String)
}

public struct ThemeDefinition: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let group: ThemeGroup
    public let tokens: [ThemeToken]
    public let ansiPalette: [String]?
    public let prefersSystemMaterials: Bool
    
    public init(
        id: String,
        displayName: String,
        group: ThemeGroup,
        tokens: [ThemeToken],
        ansiPalette: [String]? = nil,
        prefersSystemMaterials: Bool = false
    )
    
    public func hex(for role: ThemeRole) -> String
    public var preferredColorScheme: ThemePreferredColorScheme
    public func uiHex(for role: ThemeUIRole) -> String
    public var materialTintHex: String
    public var materialTintOpacity: Double
    public var terminalANSIPalette: [String]
}

public enum ThemeCatalog {
    public static let defaultID = "ghostty-default"
    public static let defaultLightID = "macos-light"
    public static let defaultDarkID = "macos-dark"
    public static let themes: [ThemeDefinition]
    public static let defaultTheme: ThemeDefinition
    public static var supportedIDs: [String]
    public static func theme(id: String) -> ThemeDefinition?
    public static func themes(in group: ThemeGroup) -> [ThemeDefinition]
}

public enum DraculaTheme {
    public static let tokens: [DraculaToken]
    public static func hex(for role: ThemeRole) -> String
}

public struct DraculaToken: Equatable, Sendable {
    public let role: ThemeRole
    public let hex: String
    public init(role: ThemeRole, hex: String)
}
```

**Key Constants:**
- 17 builtin themes (macos-light/dark, light/dark variants, Dracula, high-contrast, etc.) defined in `ThemeCatalog.themes` array.
- ANSI palette auto-derived if not explicit (16 colors from theme roles).
- Material tint opacity 0.7 for most; 1.0 for high-contrast.
- Contrast ratio calculation for accessibility (WCAG 2.0 relative luminance).

**Concurrency Notes:** All value types, enums; static `themes` array is immutable.

---

#### `src/Icons/IconSystem.swift`

**Public Types:**

```swift
public enum AppIcon: Equatable, Sendable {
    case systemSymbol(String)
    case bundledAsset(BundledIconAsset)
    
    public var systemSymbolName: String
    public var draculaRole: DraculaRole?
}

public struct BundledIconAsset: Equatable, Sendable {
    public let id: String
    public let pack: FileIconPack
    public let systemSymbolName: String
    public let draculaRole: DraculaRole
    
    public init(
        id: String,
        pack: FileIconPack,
        systemSymbolName: String,
        draculaRole: DraculaRole
    )
}

public enum IconRole: Equatable, Sendable {
    case sidebar, rightSidebar, navigateBack, navigateForward
    case settings, close, openDocument, reload, installUpdate
    case newProject, disclosureExpanded, disclosureCollapsed
    case pin, unpin, pinned, moveUp, moveDown
    case newThread, archive, unarchive, moreActions, add
    case warning, bottomTerminal, workspaceSwap
    case rightPanelMode(RightPanelMode)
    case fileStateOverlay(FileStateOverlay)
    
    public var icon: AppIcon
}

public enum FileStateOverlay: String, CaseIterable, Equatable, Identifiable, Sendable {
    case modified, added, deleted, renamed
    case ignored, untracked, conflicted
    case indexingPending, indexingFailed, externalToolUnavailable
    
    public var id: String
    public var systemSymbolName: String
}

public enum FileIconPack: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case material = "material-file-icons"
    case catppuccin = "catppuccin-file-icons"
    
    public var id: String
    public static let fallback: FileIconPack
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
    )
    
    public var asset: BundledIconAsset
}

public struct FileIconManifest: Equatable, Sendable {
    public let pack: FileIconPack
    public let sourceName: String
    public let licenseID: String
    public let entries: [FileIconManifestEntry]
    
    public init(
        pack: FileIconPack,
        sourceName: String,
        licenseID: String,
        entries: [FileIconManifestEntry]
    )
    
    public static func manifest(for pack: FileIconPack) -> FileIconManifest
}

public struct FileIconResolver: Equatable, Sendable {
    public let pack: FileIconPack
    
    public init(pack: FileIconPack = .fallback)
    
    public func icon(for entry: FileBrowserEntry, isExpanded: Bool = false) -> AppIcon
}
```

**Concurrency Notes:** All value types; no mutable state. Static manifest builders are called once per pack during init.

---

#### `src/Fonts/BundledFontCatalog.swift`

**Public Types:**

```swift
public enum BundledFontCatalog {
    public static let jetBrainsMonoFamily = "JetBrains Mono"
    
    @discardableResult
    public static func registerBundledFonts(
        diagnosticRecorder: DiagnosticEventRecording? = nil
    ) -> Bool
}
```

**Concurrency Issue (REQUIRES FIX):**
- Line 15: `nonisolated(unsafe) static var didRegister = false` — mutable static state, not thread-safe under Swift 6 strict concurrency.
- Line 23: `lock.lock()` / `lock.unlock()` — uses `NSLock()` initialized on line 14.

**Swift-6 Fix:**
Replace with an `actor`-managed registration state:
```swift
public enum BundledFontCatalog {
    private actor RegistrationState {
        var didRegister = false
        
        func registerIfNeeded(
            diagnosticRecorder: DiagnosticEventRecording?
        ) -> Bool {
            if didRegister { return true }
            // ... registration logic ...
            didRegister = true
            return success
        }
    }
    
    private static let registrationState = RegistrationState()
    
    public static func registerBundledFonts(
        diagnosticRecorder: DiagnosticEventRecording? = nil
    ) async -> Bool {
        await registrationState.registerIfNeeded(diagnosticRecorder: diagnosticRecorder)
    }
}
```

**Key Algorithm:**
- Locates `JetBrainsMono/` directory from `Bundle.main` or relative to executable.
- Registers all `.ttf` files with `CTFontManagerRegisterFontsForURL()`.
- Tolerates `.alreadyRegistered` and `.duplicatedName` errors; all others logged as failures.

---

### 4. Markdown Preview & File Browser

#### `src/MarkdownPreview/MarkdownPreviewRenderer.swift`

**Public Types:**

```swift
public enum MarkdownPreviewRenderer {
    public static func renderHTML(markdown: String, sourceURL: URL) -> String
    public static func escapeHTML(_ value: String) -> String
    public static func isMarkdownURL(_ url: URL) -> Bool
}
```

**Conformances:** Pure enum; no state.

**Key Algorithm (Markdown→HTML):**
- Block-level parser: fenced code (```/~~~), headings (#), lists (-, *, +, numbered), tables, blockquotes.
- Inline renderer: bold (**/__), italic (*/_), links `[text](url)`, images `![alt](url)`, code backticks.
- Mermaid flowchart/sequence diagram special-casing (embedded SVG rendering via JavaScript).
- HTML sanitization: allows ~27 tags (a, img, br, div, p, strong, em, etc.); blocks `on*` event handlers and `javascript:/data:text/html` URLs.
- Syntax highlighting: none; language classes added to `<pre><code>` for downstream highlighting.

**Concurrency Notes:** Pure functional; no state.

---

#### `src/FileBrowser/FileBrowserEntry.swift`

**Public Types:**

```swift
public struct FileBrowserEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let isDirectory: Bool
    public let isPruned: Bool
    
    public init(relativePath: String, isDirectory: Bool, isPruned: Bool = false)
}

public struct FileIndexMetadata: Equatable, Sendable {
    public static let currentSchemaVersion = 3
    
    public var threadID: UUID
    public var cacheKey: String?
    public var rootPath: String
    public var gitIdentity: String
    public var ignoreRulesFingerprint: String
    public var schemaVersion: Int
    public var indexedAt: Date
    public var fileCount: Int
    public var ignoredDirectoryCount: Int
    
    public init(
        threadID: UUID,
        cacheKey: String? = nil,
        rootPath: String,
        gitIdentity: String = FileIndexGitIdentity.notRepository.cacheComponent,
        ignoreRulesFingerprint: String = "",
        schemaVersion: Int = FileIndexMetadata.currentSchemaVersion,
        indexedAt: Date,
        fileCount: Int,
        ignoredDirectoryCount: Int
    )
    
    public func forThread(_ threadID: UUID) -> FileIndexMetadata
}

public struct FileBrowserState: Equatable, Sendable {
    public var rootPath: String?
    public var searchQuery: String
    public var indexedEntryCount: Int
    public var entries: [FileBrowserEntry]
    public var visibleEntries: [FileBrowserEntry]
    public var isBrowseEntryLimitApplied: Bool
    public var isVisibleEntryLimitApplied: Bool
    public var isIndexing: Bool
    public var metadata: FileIndexMetadata?
    public var errorMessage: String?
    
    public init(
        rootPath: String? = nil,
        searchQuery: String = "",
        indexedEntryCount: Int = 0,
        entries: [FileBrowserEntry] = [],
        visibleEntries: [FileBrowserEntry] = [],
        isBrowseEntryLimitApplied: Bool = false,
        isVisibleEntryLimitApplied: Bool = false,
        isIndexing: Bool = false,
        metadata: FileIndexMetadata? = nil,
        errorMessage: String? = nil
    )
}
```

**Conformances:** `Equatable`, `Sendable`; no `Codable` (cache lookup by metadata only).

**Concurrency Notes:** Pure value types.

**Key Concepts:**
- `isPruned`: directory matches ignore rule; subtree indexed on-demand when expanded.
- `FileIndexMetadata.schemaVersion`: currently 3; used for cache validation/migration.
- `cacheKey`: optional; null if not in a git repo or cache lookup fails.

---

### 5. Configuration & Persistence

#### `src/Persistence/YAAWConfiguration.swift`

**Public Types (Extensive Codable Schema):**

```swift
public struct YAAWConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var agent: AgentSettings
    public var projects: ProjectSettings
    public var theme: ThemeSettings
    public var icons: IconSettings
    public var fonts: FontSettings
    public var keyboardShortcuts: KeyboardShortcutSettings
    public var tools: ToolSettings
    public var fileBrowser: FileBrowserSettings
    public var fileIndexing: FileIndexingSettings
    
    public init(...) // full init signature with defaults
    public init(from decoder: Decoder) throws // forgiving decode
    
    public static let defaultIgnoreRules: [String]
    public var themeName: String
    public func resolvedTheme(systemAppearanceIsDark: Bool) -> ThemeDefinition
    public var ignoreRules: [String]
    public var fileIconPack: FileIconPack
    public var defaultAgentCLI: AgentCLIKind
    
    public func agentExecutableName(for kind: AgentCLIKind) -> String
    public func defaultLaunchOptions(for kind: AgentCLIKind) -> AgentLaunchOptions
    public func shortcut(for action: KeyboardShortcutAction) -> KeyboardShortcutDefinition
    
    public func validated(
        diagnosticRecorder: DiagnosticEventRecording? = nil
    ) -> YAAWConfiguration
}

// [AgentSettings, AgentLaunchDefaultSettings, AgentLaunchDefaultsSettings,
//  ProjectSettings, ThemeSettings, IconSettings, FontSettings,
//  KeyboardShortcutSettings, ToolSettings, FileBrowserSettings,
//  FileIndexingSettings — all Codable, Equatable, Sendable]

public final class YAMLConfigurationStore {
    public init(
        path: URL,
        diagnosticRecorder: DiagnosticEventRecording = LoggerDiagnosticEventRecorder.shared
    )
    
    public static func defaultPath() -> URL
    
    public func ensureFileExists() throws
    public func loadText() throws -> String
    public func validate(text: String) throws -> YAAWConfiguration
    public func load() -> YAAWConfiguration
    
    public func save(_ configuration: YAAWConfiguration) throws
    public func saveText(_ text: String) throws
    
    public static func render(
        _ configuration: YAAWConfiguration = YAAWConfiguration()
    ) -> String
}
```

**Conformances:** All public sub-structs are `Codable`, `Equatable`, `Sendable`.

**Concurrency Notes:** `YAMLConfigurationStore` is a reference type with `diagnosticRecorder` (protocol reference); no mutable shared state.

**REQUIRED MODIFICATION (per master plan):**
- **Add `schemaVersion` field to `YAAWConfiguration`** (currently missing).
- Master plan row: "add `schemaVersion` + migration hook"
- Current: `version: Int` is present (default 1, line 42), but it's not being used for schema migrations; reserved for future v16→v17 ladder step.
- **Action:** Keep `version` as-is (for overall config versioning); add a separate integer field to track schema evolutions (e.g., for right-panel-tabs feature).
- **Migration:** Call a hook in `validated()` to upgrade old snapshots.

**Key Constants:**
- Default ignore rules: `.git`, `node_modules`, `dist`, `.build`, `DerivedData`, etc. (line 1210–1227).
- Keyboard shortcut scopes: App, Project, Thread, Navigation, RightPanel, Files, ExternalOpen, Layout, Terminal, Settings.
- Font sizes: clamp 9–28 (pt); 0 in `fileBrowserSize` means inherit interface size.
- Theme selection: "system" mode follows macOS appearance with light/dark pairing.

---

### 6. Diagnostics & Core Utilities

#### `src/Diagnostics/DiagnosticEvent.swift`

**Public Types:**

```swift
public struct DiagnosticEvent: Equatable, Sendable {
    public var category: String
    public var name: String
    public var metadata: [String: String]
    
    public init(category: String, name: String, metadata: [String: String] = [:])
}

public protocol DiagnosticEventRecording: AnyObject, Sendable {
    func record(_ event: DiagnosticEvent)
}

public final class LoggerDiagnosticEventRecorder: DiagnosticEventRecording, @unchecked Sendable {
    public static let shared: LoggerDiagnosticEventRecorder
    
    public init(subsystem: String = "dev.dopsonbr.YAAW")
    
    public func record(_ event: DiagnosticEvent)
}
```

**Concurrency Issue (REQUIRES FIX):**
- Line 20: `@unchecked Sendable` — violates strict concurrency requirement.
- Lines 24–26: Private `DispatchQueue`, `NSLock`, and mutable `loggersByCategory` dictionary.

**Swift-6 Fix:**
Convert to an isolated actor:
```swift
public actor LoggerDiagnosticEventRecorder: DiagnosticEventRecording {
    public static let shared = LoggerDiagnosticEventRecorder()
    
    private let subsystem: String
    private var loggersByCategory: [String: Logger] = [:]
    
    public init(subsystem: String = "dev.dopsonbr.YAAW") {
        self.subsystem = subsystem
    }
    
    public nonisolated func record(_ event: DiagnosticEvent) {
        // Dispatch to async context
        Task {
            await self._recordIsolated(event)
        }
    }
    
    private func _recordIsolated(_ event: DiagnosticEvent) {
        let logger = logger(forCategory: event.category)
        let rendered = Self.render(event.metadata)
        logger.info("\(event.name, privacy: .public) \(rendered, privacy: .public)")
    }
    
    private func logger(forCategory category: String) -> Logger {
        if let cached = loggersByCategory[category] {
            return cached
        }
        let logger = Logger(subsystem: subsystem, category: category)
        loggersByCategory[category] = logger
        return logger
    }
}
```

---

#### `src/Core/ExternalOpen.swift`

**Public Types:**

```swift
public enum ExternalOpenToolID: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case vscode, vscodeInsiders = "vscode-insiders"
    case sublimeText = "sublime-text"
    case zed, finder, terminal, ghostty, xcode, webstorm
    
    public var id: String
    public var displayName: String
    public var isEditor: Bool
    public var systemSymbolName: String
}

public struct ExternalOpenSettings: Codable, Equatable, Sendable {
    public static let defaultTool: ExternalOpenToolID
    public static let defaultPreferred: [ExternalOpenToolID]
    
    public var default: String
    public var preferred: [String]
    
    public init(default: String = ..., preferred: [String] = ...)
    public var defaultToolID: ExternalOpenToolID
    public var preferredToolIDs: [ExternalOpenToolID]
    func validated() -> ExternalOpenSettings
}

public enum ExternalOpenTargetKind: Equatable, Sendable {
    case directory, file
}

public struct ExternalOpenTarget: Equatable, Sendable {
    public var url: URL
    public var kind: ExternalOpenTargetKind
    
    public init(url: URL, kind: ExternalOpenTargetKind)
    
    public func launchURL(for tool: ExternalOpenToolID) -> URL
    public func shouldRevealInFinder(for tool: ExternalOpenToolID) -> Bool
}

public enum ExternalOpenToolResolver {
    public static func availableTools(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> [ExternalOpenToolID]
    
    public static func defaultTool(
        settings: ExternalOpenSettings,
        detectedTools: Set<ExternalOpenToolID>
    ) -> ExternalOpenToolID?
    
    public static func availableEditorTools(...) -> [ExternalOpenToolID]
    public static func defaultEditorTool(...) -> ExternalOpenToolID?
}
```

**Conformances:** Enums are `Codable`, `Equatable`, `Sendable`; structs are `Equatable`, `Sendable`.

**Concurrency Notes:** Pure value types and pure functional resolvers.

---

#### `src/Core/AppSelection.swift`

**Public Types:**

```swift
public struct AppSelection: Equatable, Sendable, Codable {
    public var projectID: UUID
    public var threadID: UUID?
    
    public init(projectID: UUID, threadID: UUID?)
}

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var entries: [AppSelection]
    public private(set) var cursor: Int
    public let limit: Int
    
    public init(initial: AppSelection, limit: Int = 50)
    
    public var current: AppSelection
    public var canGoBack: Bool
    public var canGoForward: Bool
    
    public mutating func push(_ selection: AppSelection)
    public mutating func goBack() -> AppSelection?
    public mutating func goForward() -> AppSelection?
}
```

**Conformances:** `Equatable`, `Sendable`; `AppSelection` also `Codable`.

**Concurrency Notes:** Pure value type with only `mutating` methods (no shared state).

---

#### `src/Core/ProjectDirectoryState.swift`

**Public Types:**

```swift
public enum ProjectDirectoryState: Equatable, Sendable {
    case available(path: String)
    case missing(path: String)
    
    public var path: String
    public var isMissing: Bool
}
```

**Conformances:** `Equatable`, `Sendable`.

---

## Summary: Conformances & Concurrency Compliance

### Full Inventory: Sendable Conformance

| Type | Sendable | Codable | Equatable | Notes |
|---|---|---|---|---|
| Project | ✓ | — | ✓ | Pure value type |
| ProjectMoveDirection | ✓ | — | ✓ | Enum |
| AgentCLIKind | ✓ | ✓ | ✓ | String enum |
| AgentThread | ✓ | — | ✓ | Pure value type |
| AgentLaunchOptions | ✓ | ✓ | ✓ | Pure value type |
| AgentPermissionMode | ✓ | ✓ | ✓ | Pure value type |
| AgentLaunchOptionsArgumentError | ✓ | — | ✓ | Error enum |
| ThreadActivityStatus | ✓ | ✓ | ✓ | String enum |
| ThreadActivitySource | ✓ | ✓ | ✓ | String enum |
| ThreadActivityState | ✓ | — | ✓ | Pure value type; sanitizes text in init |
| ThreadActivityEvent | ✓ | — | ✓ | Pure value type |
| ThreadActivityText | ✓ | — | — | Enum of pure functions |
| ThreadRelativeTimeFormatter | ✓ | — | — | Enum of pure functions |
| ThreadActivityNotification | ✓ | — | ✓ | Pure value type |
| ThreadActivityNotificationDispatching | ✓ | — | — | Protocol; AnyObject & Sendable |
| ThreadActivityBadgeUpdating | ✓ | — | — | Protocol; AnyObject & Sendable |
| NoopThreadActivityNotificationDispatcher | ✓ | — | — | Final class; no state |
| NoopThreadActivityBadgeUpdater | ✓ | — | — | Final class; no state |
| LayoutState | ✓ | — | ✓ | Pure value type |
| RightPanelMode | ✓ | — | ✓ | String enum |
| RightPanelTabKind | ✓ | — | ✓ | String enum |
| RightPanelTab | ✓ | — | ✓ | Pure value type |
| RightPanelState | ✓ | — | ✓ | Pure value type; mutable but no shared state |
| ThemeRole | ✓ | — | ✓ | String enum |
| ThemeGroup | ✓ | — | ✓ | String enum |
| ThemePreferredColorScheme | ✓ | — | ✓ | String enum |
| ThemeUIRole | ✓ | — | ✓ | String enum |
| ThemeToken | ✓ | — | ✓ | Pure value type |
| ThemeDefinition | ✓ | — | ✓ | Pure value type |
| DraculaToken | ✓ | — | ✓ | Pure value type |
| ThemeCatalog | ✓ | — | — | Enum of immutable statics & pure functions |
| DraculaTheme | ✓ | — | — | Enum of immutable statics & pure functions |
| AppIcon | ✓ | — | ✓ | Enum |
| BundledIconAsset | ✓ | — | ✓ | Pure value type |
| IconRole | ✓ | — | ✓ | Enum |
| FileStateOverlay | ✓ | — | ✓ | String enum |
| FileIconPack | ✓ | ✓ | ✓ | String enum |
| FileIconManifestEntry | ✓ | — | ✓ | Pure value type |
| FileIconManifest | ✓ | — | ✓ | Pure value type |
| FileIconResolver | ✓ | — | ✓ | Pure value type |
| BundledFontCatalog | ⚠️ | — | — | **ISSUE:** mutable static + NSLock; needs actor conversion |
| MarkdownPreviewRenderer | ✓ | — | — | Enum of pure functions |
| FileBrowserEntry | ✓ | — | ✓ | Pure value type |
| FileIndexMetadata | ✓ | — | ✓ | Pure value type |
| FileBrowserState | ✓ | — | ✓ | Pure value type |
| YAAWConfiguration | ✓ | ✓ | ✓ | Pure value type |
| [AgentSettings + 8 sub-configs] | ✓ | ✓ | ✓ | All pure value types |
| YAMLConfigurationStore | ✓ | — | — | Reference type; diagnosticRecorder is Sendable protocol |
| DiagnosticEvent | ✓ | — | ✓ | Pure value type |
| DiagnosticEventRecording | ✓ | — | — | Protocol; AnyObject & Sendable |
| LoggerDiagnosticEventRecorder | ⚠️ | — | — | **ISSUE:** @unchecked Sendable; needs actor conversion |
| ExternalOpenToolID | ✓ | ✓ | ✓ | String enum |
| ExternalOpenSettings | ✓ | ✓ | ✓ | Pure value type |
| ExternalOpenTargetKind | ✓ | — | ✓ | Enum |
| ExternalOpenTarget | ✓ | — | ✓ | Pure value type |
| ExternalOpenToolResolver | ✓ | — | — | Enum of pure functions |
| AppSelection | ✓ | ✓ | ✓ | Pure value type |
| NavigationHistory | ✓ | — | ✓ | Value type with mutating methods |
| ProjectDirectoryState | ✓ | — | ✓ | Enum |

### Identified Swift-6-Strict-Concurrency Issues (TO FIX)

1. **`BundledFontCatalog` (line 15):** Mutable static `didRegister` + `NSLock` on line 14.
   - **Fix:** Convert to isolated actor with async registration.

2. **`LoggerDiagnosticEventRecorder` (line 20):** `@unchecked Sendable` marker; mutable `loggersByCategory` Dictionary + `NSLock` + `DispatchQueue`.
   - **Fix:** Convert to isolated actor; dispatch `record()` calls via `Task`.

---

## Behaviors & Edge Cases to Preserve

### Thread Activity Text Sanitization
- **File:** `ThreadActivityText.swift`, lines 141–162
- **Behavior:** Removes ANSI escapes (OSC 7 title setting, CSI sequences, other control codes) and collapses whitespace; max 240 chars.
- **Regex Patterns:**
  ```
  \u{001B}\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\)  # OSC 7
  \u{001B}\[[0-9;?]*[ -/]*[@-~]                           # CSI
  \u{001B}[@-Z\-_]                                        # Other C1
  ```
- **Test Assertion:** Markdown with formatting (`**bold**`) collapses to space-separated; ANSI codes disappear.

### Right Panel Persistence
- **File:** `RightPanelTab.swift`, lines 154–156
- **Behavior:** `persistenceSnapshot` returns only default tabs (Files, Browser, Git, nvim), dropping custom browser/nvim tabs.
- **Rationale:** Transient UI state is not persisted; reload starts fresh with defaults.
- **Per Plan:** "now persisted" for expanded folders / selected file — this applies to per-thread folder expansion in the Files pane, NOT to the Tab collection itself.

### Layout Clamping
- **File:** `LayoutState.swift`, lines 31–49
- **Behavior:** All dimensions clamped in `init`, not setter calls.
- **Terminal height:** Further constrained by available window height (max 45% of window height).
- **Test Assertion:** Drag sidebar to invalid width → clamped to [180, 520].

### Theme Fallback & Validation
- **File:** `ThemeSettings.swift`, lines 351–361
- **Behavior:** Unknown theme ID → falls back to system mode (light/dark pairing).
- **Test Assertion:** Load config with `active: "unknown-theme"` → validated to `system` mode with safe light/dark defaults.

### External Open Tool Resolution
- **File:** `ExternalOpen.swift`, lines 158–183
- **Behavior:** Filters preferred list by detected tools; adds Finder if no editor available.
- **Test Assertion:** If Zed unavailable but VS Code & Finder detected → available=[vscode, finder]; default=vscode.

---

## Constants & Key Values

| Constant | Value | File | Use |
|---|---|---|---|
| `maximumPreviewLength` | 240 | ThreadActivityText | Activity notification preview max chars |
| `defaultSidebarWidth` | 250 pt | LayoutState | Initial sidebar width |
| `defaultRightPanelWidth` | 360 pt | LayoutState | Initial right panel width |
| `defaultGlobalTerminalHeight` | 140 pt | LayoutState | Initial terminal pane height |
| `minimumSidebarWidth` | 180 pt | LayoutState | Min sidebar width |
| `maximumSidebarWidth` | 520 pt | LayoutState | Max sidebar width |
| `minimumRightPanelWidth` | 280 pt | LayoutState | Min right panel width |
| `minimumGlobalTerminalHeight` | 96 pt | LayoutState | Min terminal height |
| `maximumGlobalTerminalHeight` | 420 pt | LayoutState | Max terminal height |
| `FileIndexMetadata.currentSchemaVersion` | 3 | FileIndexMetadata | Current file index cache schema |
| `jetBrainsMonoFamily` | "JetBrains Mono" | BundledFontCatalog | Font name |
| `defaultPermissionModeID` | "default" | AgentLaunchOptions | Permission mode fallback |
| Keyboard shortcut limit | 50 entries | NavigationHistory | Max back/forward history |
| Font size range | 9–28 pt | YAAWConfiguration | Clamped on validated() |
| File browser font size 0 | Inherit interface | FontSettings | Special value meaning inheritance |

---

## Port Status & Acceptance Criteria

**These types port with ~95% verbatim code; the 5% delta is:**

1. Add `schemaVersion` field to `YAAWConfiguration` (per master plan).
2. Convert `BundledFontCatalog.registerBundledFonts()` to async (returns Task or uses actor).
3. Convert `LoggerDiagnosticEventRecorder` from `@unchecked Sendable` to isolated actor.
4. Fix any `FilePathNormalizer` and `FileIndexGitIdentity` references (externalized helper enums).

**Acceptance:**
- Port compiles under Swift 6 strict concurrency `complete` with no `@unchecked Sendable` and zero new `swiftlint:disable` directives.
- All ported tests (identity, validation, clamp, parse, infer, resolve) pass.
- Appearance (theme tokens, icons, fonts) visually identical to original.
- No breaking API changes to public signatures.

