# Chunk F: Feature Views + Appearance Parity — Port Specification

**Status:** Spec document (not implementation)  
**Target Architecture:** New thin SwiftUI feature views consuming @MainActor @Observable stores (Chunk E outputs)  
**Acceptance:** Screenshot parity vs `docs/examples/screenshots/current/*` + every interactive control has `accessibilityIdentifier` + keyboard shortcuts wired + hot-reload of theme/font works on live terminals  

---

## 1. View Hierarchy & Thin View Contracts

### 1.1 Root Assembly (YAAWApp + RootView)

**YAAWApp** (`src/App/YAAWApp.swift` — KEEP existing structure)
- **Single-instance sweep:** `YAAWApp.init` calls static `duplicateInstanceSweep` (lines 31-47) — SIGTERM older same-bundle-id instances by launch date, fallback `forceTerminate()` after 3s. **NOT via delegate launching callbacks** (LaunchServices launches bypass delegate). [Cited: Master Plan §Recent changes, YAAWApp.swift]
- **Titlebar toolbar:** `.windowToolbarStyle(.unifiedCompact)` on main window (line 201).
- **Font registration:** `BundledFontCatalog.registerBundledFonts(diagnosticRecorder:)` in `init` (line 54). JetBrains Mono vendored + registered, ligatures toggle plumbed to both editor + terminal rendering configs. [Cited: Master Plan §Fonts]
- **System appearance seeding:** `seededSystemAppearanceIsDark()` reads `AppleInterfaceStyle` defaults key (line 139); KVO-corrected by delegate within runloop.
- **Settings window:** Standalone `Window("Settings", id: Self.settingsWindowID)` scene (lines 430-437); `.defaultSize(width: 980, height: 680)`.
- **Build info in About dialog:** `.version: AppBuildInfo.commit` in commandGroup (lines 204-208). `AppBuildInfo.summary` shown in General settings (line 44).

**RootView** (`src/App/RootView.swift` — rewrite as thin consumer)
- **Observe:** read-only access to `AppModel` (current god object; will become dispatchers to stores).
- **Chromebus:** `chromeToolbar` (lines 66-135) — native toolbar w/ SF Symbols, all buttons carry `accessibilityIdentifier`. Icons: sidebar toggle, nav-back/forward, external-open split-button, install-update, workspace-swap (colored pink when active), right-panel toggle, settings, all via `IconRole` enum. All via `@ToolbarContentBuilder`.
- **Workspace layout:** `WorkspaceSplitView` (line 235) passes sidebar/main/right/bottom regions; managed by `WorkspaceSplitViewController` (NSViewController + AppKit split layout).
- **Terminal lifecycle:** `IsolatedToolRuntime` StateObject (line 20); persists while thread is live. On app terminate, `shutdownAllHosts()` (line 60). On terminal termination, `onTerminalTerminated` callback (lines 35-37). **NOTE: current impl uses overlay windows + viewport polling (Chunk D will replace with composited IOSurface); old `IsolatedToolViewportReporter` deleted in rewrite.**
- **Forwarded shortcuts:** `onKeyboardShortcut` callback (lines 38-40) → `handleForwardedTerminalShortcut` (lines 346-367) dispatches to `performForwardedTerminalShortcut` (lines 370-432). **All shortcuts routed through here except settings scope.**
- **Master node tree:**
  ```
  RootView
    ├─ .toolbar { chromeToolbar }
    ├─ .font(interfaceFont)
    ├─ .environment(\.fontSettings, fonts)
    ├─ .environment(\.appTheme, resolvedTheme)
    ├─ .environment(\.colorScheme, colorScheme)
    ├─ .environmentObject(terminalRuntime)
    ├─ WorkspaceSplitView
    │   ├─ sidebar: SidebarView
    │   ├─ main: MainWorkspaceView (agent terminal for selected thread)
    │   ├─ right: RightPanelView (files/browser/nvim/git tabs)
    │   └─ bottom: BottomTerminalBar
    └─ SettingsWindowView (separate Window scene)
  ```

### 1.2 Sidebar (SidebarView)

**Location:** `src/App/RootView.swift` lines 527–595 (private struct `SidebarView`)

**Contract:** consume **WorkspaceStore** (from Chunk E)
- `activeProjects: [Project]` — pinned + unpinned, sorted
- `activeThreads(for: Project.ID) -> [AgentThread]` — per-project, pinned first
- `selectedProjectID: UUID?`
- `selectedThreadID: UUID?`
- `isProjectExpanded(id:) -> Bool`
- `archivedProjects: [Project]`
- `archivedThreads: [AgentThread]` (global, not per-project)
- `threadActivity(for: AgentThread.ID) -> ThreadActivityState` (unread badge, status icon, preview)
- `lastInteractionDate(for: AgentThread) -> Date` (idle age formatter)

**View structure:**
```
VStack {
  "Projects" header + New button
  ScrollView { project sections }
  Spacer
  "Archived" collapsible section (global)
  "Collapse Sidebar" button
}
.padding(18)
.sheet(isProjectSheetPresented) { ProjectCreationSheet }
.sheet(threadSheetProject) { ThreadChoiceSheet }
.sheet(renameThread) { ThreadRenameSheet }
```

**Subviews:**

1. **ProjectSidebarSection** (lines 598–706)
   - Disclosure toggle (expand/collapse project threads)
   - Project button (shows display name + root path, selection highlight)
   - Hover-only "New Thread" + more-actions menu
   - Menu: Pin/Unpin, Archive (if allowed)
   - Draggable (drag project ID as string UUID); drop target accepts String (reorder before target)
   - Nested thread list when expanded
   - **AX:** disclosure label ("Collapse"/"Expand"), project label, menu help

2. **ActiveThreadRow** (lines 709–802)
   - Thread name (bold if unread) + preview text (yellow if unread, comment-gray if read)
   - Activity status icon: spinner (working), exclamation (needs input), checkmark (complete), dot (inactive)
   - Idle age label (e.g. "2m") for inactive threads (TimelineView(periodic 60s))
   - Agent CLI icon (badge + hover help)
   - Hover-only more-actions menu: Rename, Pin/Unpin, Archive
   - **AX:** "Thread [name], [CLI], [status]"

3. **ThreadIdleAgeLabel** (lines 805–821)
   - `TimelineView(.periodic(from: Date(), by: 60))` → `ThreadRelativeTimeFormatter.shortElapsed(since:, now:)`
   - Updated every 60s; monospaced digits

4. **ThreadActivityIndicator** (lines 823–852)
   - `.working` → ProgressView (small, cyan tint)
   - `.needsInput` → exclamation icon (filled if unread, hollow if read); yellow
   - `.complete` → checkmark.circle.fill; green
   - `.inactive` → circle; comment-gray
   - All help-tipped

5. **GlobalArchivedThreadsSection** (lines 922–985)
   - Disclosure button (Archived + count badge in orange)
   - When expanded: list of archived projects + archived threads (mixed flat list)
   - **ArchivedProjectRow** (988–1042): restore button + menu (Unarchive), drag-disabled, path as help-text
   - **ArchivedThreadRow** (1045–1109): restore button + menu (Rename, Pin/Unpin, Unarchive)

**Materials & appearance:**
- Sidebar sits behind `SidebarView` inside `WorkspaceSplitHostView` (AppKit) as two layers: NSVisualEffectView `.sidebar` / `.behindWindow` / `.followsWindowActiveState` + tint overlay (lines 142-143, 217-219, 263-282 WorkspaceSplitView.swift).
- Selection pill: `dracula(.currentLine)` background, 8pt corner radius, 4pt h-inset.
- Hover pill opacity: 0.4x opaque.
- All glyphs: `.medium` weight (ChromeMetrics.glyphWeight); sizes via ChromeMetrics.

**Sheet modals:**
- **ProjectCreationSheet** (1112–1222): VStack(title "New Project", directory picker + display name field, error message, Cancel/Create buttons). Frame 560pt wide. Directory defaults to home; name autofills from last path component.
- **ThreadRenameSheet** (1225–1293): VStack(title, CLI badge, name TextField, Cancel/Rename buttons, error). Frame 420pt wide. Errors caught: `.sessionRenameNotSupported`, `.emptyThreadName`.
- **ThreadChoiceSheet** (ThreadChoiceSheet.swift): Agent card grid + details panel (see §1.5 below).

---

### 1.3 Main Workspace (MainWorkspaceView + TerminalPlaceholderView)

**Location:** `src/App/RootView.swift` lines 1296–1405

**Contract:** consume **WorkspaceStore + ActivityStore**

**MainWorkspaceView:**
```
VStack {
  if projectDirMissing: MissingDirectoryBanner
  if threadWorkdirMissing: MissingDirectoryBanner
  if sessionLinkRequired: SessionLinkRequiredView
  else: TerminalPlaceholderView (or no terminal for selected thread)
}
.padding(8)
```

**MissingDirectoryBanner** (referenced but defined elsewhere; styled alert with path + guidance message).

**SessionLinkRequiredView** (1407–1438): two buttons (Link Session, Start New Session); displayed when thread needs resume-session linkage.

**TerminalPlaceholderView** (WorkspaceSupportViews.swift, lines 5–47):
- Receives `TerminalLaunchRequest?` + unavailable message
- If request present: `IsolatedAgentTerminalView` (see §1.6 Terminal Surface Host)
- Else: Text placeholder in Dracula background
- `accessibilityLabel`: "[title] terminal"

**Bottom Terminal Bar** (BottomTerminalBar, lines 178–220):
- Header button: "Bottom Terminal" label + Expanded/Collapsed status
- If expanded: nested `TerminalPlaceholderView` for bottom terminal request
- `onAppearExpanded` callback (activation hook)
- Padding + Dracula currentLine background

---

### 1.4 Right Panel (RightPanelView)

**Location:** `src/App/RootView.swift` lines 1540–[RightPanelView struct continues; read further lines to see full impl]

**Contract:** consume **RightPanelStore** (from Chunk E)
- `selectedRightPanelState.tabs: [RightPanelTab]` (Files, Browser, Nvim, Git)
- `selectRightPanelTab(id:)`, `selectRightPanelMode(_:)`
- `cycleRightPanelModeForward/Backward()`
- `openBrowserTab()` (new tab)

**Tab structure:**
```
ScrollView(.horizontal) {
  HStack { tab buttons ... }
  Menu(+chevron) { Add File/Browser/Nvim/Git ... }
}
[Tab content area]
```

**Tabs (by mode):**
1. **Files** (FileBrowserPanel, lines 4–182 FileBrowserPanelView.swift)
   - Search field (250ms debounce)
   - Refresh button (cyan)
   - Status line (e.g. "42 items, 3 collapsed directories" or "Showing 10 of 200 matches")
   - Tree (when search empty) or search results (when query filled)
   - Max 50k visible tree rows (defensive ceiling; status warns if hit)
   - Right-click context menu: Copy path (relative/full), Open in browser, Open in editor, Rename

2. **Browser** (WKWebView isolated; not detailed here; HTML/MD/PDF/image navigation)

3. **Nvim** (embedded; fallback vim→vi)

4. **Git** (lazygit subprocess; fallback `git diff` text)

**Appearance:**
- Tab buttons: horizontal scroll, 4pt spacing
- Add menu: system symbol + chevron, small glyphs
- Content area: max-width/height fill
- Tree rows: depth-indented (14pt per level), disclosure icon (10pt), file icon (13pt), truncated name (inherit font-browser setting)

---

### 1.5 Settings Window (SettingsWindowView + Panes)

**Location:** `src/App/Settings/SettingsWindowView.swift` (lines 4–164)

**Structure:** NavigationSplitView (sidebar + detail); `.defaultSize(width: 980, height: 680)`.

**Sidebar:**
- Search TextField (filter sections)
- List (NavigationLink style)
- Sections: General, Agents, Appearance, Keyboard Shortcuts, Config File
- `accessibilityIdentifier`: "settings-sidebar-search", "settings-sidebar-[section]"

**Sections (consumed from SettingsModel + AppModel):**

1. **GeneralSettingsView** (GeneralSettingsView.swift, lines 4–86)
   - Default agent picker (Codex/Claude/Opencode/Copilot)
   - Markdown/HTML default (Preview vs Editor segmented picker)
   - CLI options refresh button
   - Build info (AppBuildInfo.summary, selectable text, cyan color)
   - Global chats directory (TextField + chooser button + save)
   - **AX:** "settings-default-agent-picker", "settings-markdown-html-open-picker", etc.

2. **AppearanceSettingsView** (AppearanceSettingsView.swift, lines 5–224)
   - **Theme:** Picker (System + ThemeCatalog groups + custom). When System: additional light/dark pickers.
   - **Fonts:** Six pickers (interface/editor/terminal/fileBrowser families + sizes) — families pinned (System / System-Mono / JetBrains Mono + installed).
   - **Ligatures:** Toggle ("Enable font ligatures in editor and terminals")
   - **AX:** "settings-theme-picker", "settings-interface-font-picker", "settings-font-ligatures-toggle", etc.

3. **KeyboardShortcutsSettingsView** (KeyboardShortcutsSettingsView.swift)
   - List of actions grouped by scope (App/Project/Thread/Navigation/Right Panel/Files/External Open/Layout/Terminal/Settings)
   - Per-action: display name + current key binding TextField (editable; validation on blur)
   - Duplicate detection (visual warning if two actions bound to same combo)
   - Restore defaults button
   - **AX:** "keyboard-shortcut-[action]"

4. **AgentsSettingsView** (AgentsSettingsView.swift)
   - Per-agent (Codex/Claude/Opencode/Copilot): executable name, permission mode picker, additional args field
   - Fetches from AppModel.agentCLIOptionCatalog
   - Save/Revert controls
   - **AX:** "settings-agent-[kind]-executable", etc.

5. **ConfigFileSettingsView** (ConfigFileSettingsView.swift)
   - Large TextEditor (YAML source)
   - Validation on blur; error banner if parse fails (never overwrites on error)
   - Save/Reload/Revert buttons
   - Open external button (NSWorkspace.open)
   - **AX:** "config-file-editor"

**Materials:** sidebar uses SidebarMaterialBackground (NSVisualEffectView .sidebar / .behindWindow / .followsWindowActiveState + theme tint overlay; reduce-transparency honored).

---

### 1.6 Terminal Surface Host View (TerminalSurfaceHostView)

**Location:** WorkspaceSupportViews.swift, lines 54–176 (IsolatedAgentTerminalView)

**NOTE:** Current impl uses overlay windows + viewport polling; **Chunk D will replace with composited IOSurface/CAContext remote layer**. This spec documents the HOST VIEW surface (the pane view that will composite the helper's rendered surface).

**New surface in rewrite:**
```swift
struct TerminalSurfaceHostView: NSViewRepresentable {
  // Chunk D: RenderHostClient fills in the actual implementation
  let role: TerminalRole
  let launch: IsolatedTerminalLaunch
  
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    // Compositing layer will be inserted here (IOSurface ring or CALayerHost)
    return view
  }
  
  func updateNSView(_ nsView: NSView, context: Context) {
    // Update layer.contents or CALayerHost reference on hot-reload
    // (theme/font changes without restarting helper)
  }
}
```

**Current placeholder behavior (pre-Chunk-D):** IsolatedAgentTerminalView (lines 54–176)
- Color.black background (until helper renders)
- IsolatedToolViewportReporter overlay (0.15s polling; **DELETED in Chunk D**)
- Forwarded shortcuts from terminal helper
- Overlay states: idle/launching (status message), crashed (error + restart button), exited (exit code + restart)
- **AX:** "[role] terminal"

**Hot-reload contract (Chunk D):**
- On theme/font change: RenderHostClient receives `setRendering(config)` message (lines 505-506 Master Plan). Helper re-renders without restart. Helper's IOSurface or CAContext updates (frame-ready handshake).
- On terminal change (cwd/env/command): relaunch helper (old process killed, new one started).

---

## 2. Keyboard Shortcuts & Actions

**Enum:** `KeyboardShortcutAction` (YAAWConfiguration.swift, lines 553–[exhaustive list])

**Scopes:** App / Project / Thread / Navigation / Right Panel / Files / External Open / Layout / Terminal / Settings

**Master binding list** (from YAAWApp.swift CommandGroups + RootView forwarded shortcuts):

| Scope | Action | Default Binding | Handler |
|-------|--------|-----------------|---------|
| App | openSettings | Cmd+, | `openWindow(id: settingsWindowID)` |
| App | newProject | Cmd+N | NSOpenPanel + `createProject` |
| Project | newThread | N/A | `createThread(agentCLI: nil)` or sheet |
| Project | toggleSelectedProjectPinned | N/A | toggle pin state |
| Project | moveSelectedProjectUp/Down | N/A | reorder |
| Project | toggleSelectedProjectExpanded | ⌘+= (expand) | toggle disclosure |
| Project | toggleSelectedProjectArchiveExpanded | N/A | archive section disclosure |
| Thread | toggleSelectedThreadPinned | N/A | toggle pin |
| Thread | archiveSelectedThread | ⌘+E | archive (remove from active) |
| Thread | unarchiveSelectedThread | ⌘+U | restore from archive |
| Navigation | navigateBack | Cmd+[ | pop history stack |
| Navigation | navigateForward | Cmd+] | push history stack |
| Right Panel | previousRightPanelMode | Cmd+Shift+[ | cycle backward (files→git→nvim→browser) |
| Right Panel | nextRightPanelMode | Cmd+Shift+] | cycle forward |
| Right Panel | selectFilesRightPanelMode | Cmd+1 | set mode to files |
| Right Panel | selectGitRightPanelMode | Cmd+2 | set mode to git |
| Right Panel | selectNvimRightPanelMode | Cmd+3 | set mode to nvim |
| Files | refreshFiles | Cmd+R | refresh index |
| Files | openSelectedFileInNvim | Cmd+Shift+O | send path to nvim |
| External Open | openSelectedDirectory* | Cmd+O (default) + per-tool | NSWorkspace.open(url, configuration:) |
| External Open | openSelectedFile* | (none default) | NSWorkspace.open(url, configuration:) |
| Layout | toggleSidebar | Cmd+B | collapse/expand sidebar |
| Layout | toggleRightPanel | Cmd+' | collapse/expand right panel |
| Layout | swapMainAndRightPanels | Cmd+\ | swap workspace orientation |
| Terminal | toggleBottomTerminal | Cmd+J | collapse/expand bottom terminal |
| Global | quit | Cmd+Q | NSApplication.terminate() |
| Settings | (all settings actions) | (custom) | in Settings window only |

**Shortcut customization:**
- `KeyboardShortcutSettings` YAML section: `{action: {key: "key", modifiers: [command, shift, ...]}}`
- Empty key/modifiers = intentionally unbound
- Validation: no duplicate signatures; invalid key ignored (fallback to default)
- Model tracks via `keyboardShortcutDefinition(for:)` + `isKeyboardShortcutEnabled(for:)`

**Accessibility identifiers for all shortcuts:**
- Toolbar buttons: "toggle-sidebar-button", "navigate-back-button", "toggle-right-panel-button", "open-settings-button", "swap-main-and-right-panels-button", etc.
- Sidebar: "new-project-button" (section header), thread context menus
- Settings pickers/toggles: "settings-theme-picker", "settings-font-ligatures-toggle", etc.

---

## 3. Appearance & Materials

### 3.1 Native Titlebar & Toolbar

- Main window: `.windowToolbarStyle(.unifiedCompact)` (YAAWApp.swift line 201)
- Toolbar items: standard SF Symbols at 15pt (toolbar size), no custom backgrounds
- Dracula foreground color applied via `.foregroundStyle(dracula(.foreground))`
- Native materials automatically apply to toolbar area (Liquid Glass)

**Removed in rewrite:** custom header chrome from old version (deleted in commit 1abc922)

### 3.2 Sidebar Material & Theme Tint

**WorkspaceSplitHostView** (WorkspaceSplitView.swift, lines 142–282):
- NSVisualEffectView `.sidebar` blendingMode `.behindWindow` state `.followsWindowActiveState`
- Theme tint overlay: NSView with `layer.backgroundColor = NSColor(hex: theme.materialTintHex).withAlphaComponent(tintOpacity)`
- **Reduce Transparency fallback:** When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true, tint opacity = 1.0 (fully opaque, no material)
- Default opacity: theme's `materialTintOpacity` (typically 0.08–0.15 for Dracula)

**Content backdrop:** opaque background behind main/right/bottom (dracula(.background) color)

### 3.3 Theme System

**ThemeSettings** (YAAWConfiguration.swift lines 310–422):
- **Active mode:** "system" (follow macOS light/dark) or fixed theme ID
- **Light/dark pairings:** `light` + `dark` theme IDs selected per-appearance
- **ThemeCatalog:** built-in themes (Dracula + others) + custom overrides
- **Resolution:** `resolvedTheme(systemAppearanceIsDark:)` returns final ThemeDefinition

**Built-in themes:**
- **Dracula** (DraculaTheme.swift): ANSI palette + all Dracula colors (background, foreground, comment, cyan, purple, pink, yellow, orange, red, green)
- System light/dark defaults from catalog

**Custom themes:** YAML under `theme.custom: {id: "hexvalue", ...}`

**SystemAppearanceObserver** (YAAWApp.swift, delegate; KVO on `AppleInterfaceStyle` UserDefaults key):
- Polls systemAppearanceIsDark
- Calls `AppModel.updateSystemAppearance(isDark:)`
- Triggers theme resolution + re-render

**Live following:** SettingsWindowView (line 22) observes `appModel.configuration.themeName` and updates `selectedThemeID`

### 3.4 Fonts & Ligatures

**FontSettings** (YAAWConfiguration.swift lines 464–537):
- **Families:** interfaceFamily, editorFamily, terminalFamily, fileBrowserFamily (inherit = follow interface)
- **Sizes:** interfaceSize, editorSize, terminalSize, fileBrowserSize (clamped 8–32pt per family)
- **Ligatures toggle:** `fonts.ligatures: bool` (default true)

**Registration & plumbing:**
- `BundledFontCatalog.registerBundledFonts()` in YAAWApp.init (line 54)
- JetBrains Mono vendored + registered (Fonts/ directory)
- Editor + Terminal: use `editorFont()` / `terminalFont()` from FontSettings, passing ligatures flag
- **Chunk D hot-reload:** `IsolatedTerminalLaunch` includes rendering config with font family + ligatures → helper's Ghostty renders with `font-feature=liga:on` (if enabled)

**Appearance settings:** AppearanceSettingsView (lines 46–129) provides pickers for all families + sizes + ligatures toggle

### 3.5 Divider Styling

**WorkspaceDividerView** (WorkspaceSplitView.swift, lines 542–684):
- Three dividers: sidebar (vertical), right panel (vertical), bottom terminal (horizontal)
- Colors (from theme): fillColor (currentLine, alpha 0.55–0.95 on hover), lineColor (comment, thin stroke), activeLineColor (cyan, when dragging)
- Corner radius: none (raw line)
- Cursor: resizeLeftRight / resizeUpDown per orientation
- Double-click to reset to defaults (via `onReset` callback)

---

## 4. View Contracts & Dependencies

### 4.1 Store Interfaces (Chunk E outputs; consumed by Chunk F)

Assumed to be @MainActor @Observable per master plan:

**WorkspaceStore:**
```swift
@MainActor @Observable
final class WorkspaceStore {
  var activeProjects: [Project]
  var selectedProjectID: UUID?
  var selectedThreadID: UUID?
  var selectedProject: Project? { get }
  var selectedThread: AgentThread? { get }
  
  func selectProject(id: UUID)
  func selectThread(id: UUID)
  func createProject(displayName: String, rootDirectory: URL) throws
  func createThread(projectID: UUID, agentCLI: AgentCLIKind?, ...) throws
  func toggleProjectPinned(id: UUID)
  func archiveProject(id: UUID)
  func unarchiveProject(id: UUID)
  func toggleThreadPinned(id: UUID)
  func archiveThread(id: UUID)
  func unarchiveThread(id: UUID)
  func navigateBack()
  func navigateForward()
  // ... (all project/thread mutations)
}
```

**ActivityStore:**
```swift
@MainActor @Observable
final class ActivityStore {
  func threadActivity(for id: UUID) -> ThreadActivityState
  var unreadCount: Int { get }
  // ... (unread dots, notifications, badges)
}
```

**LayoutStore:**
```swift
@MainActor @Observable
final class LayoutStore {
  var isSidebarCollapsed: Bool
  var isRightPanelCollapsed: Bool
  var isBottomTerminalExpanded: Bool
  var layoutState: LayoutState // widths, heights
  
  func toggleSidebarCollapsed()
  func setSidebarWidth(_ width: Double, persist: Bool)
  // ... (similar for right panel, bottom terminal)
}
```

**SettingsStore:**
```swift
@MainActor @Observable
final class SettingsStore {
  var configuration: YAAWConfiguration
  var resolvedTheme: ThemeDefinition { get }
  var systemAppearanceIsDark: Bool
  
  func updateSystemAppearance(isDark: Bool)
  func reloadConfiguration(_ config: YAAWConfiguration)
}
```

**RightPanelStore:**
```swift
@MainActor @Observable
final class RightPanelStore {
  var selectedRightPanelMode: RightPanelMode
  var tabs: [RightPanelTab]
  
  func selectRightPanelTab(id: String)
  func cycleRightPanelModeForward()
  func cycleRightPanelModeBackward()
}
```

### 4.2 AppEnvironment (Chunk E container)

```swift
struct AppEnvironment {
  let workspace: WorkspaceStore
  let layout: LayoutStore
  let activity: ActivityStore
  let settings: SettingsStore
  let rightPanel: RightPanelStore
  let renderHostClient: RenderHostClient // (Chunk D)
  
  // Constructor injection for actors
  let persistence: PersistenceActor
  let fileIndex: FileIndexActor
  let sessionBinding: SessionBindingActor
}
```

---

## 5. Concurrency Model (Swift 6 Strict)

### 5.1 Current Hazards (from AppModel)

- **AppModel** is `@unchecked Sendable` (3,188 lines; 8 domains; 17 @Published properties)
- Hand-rolled generation counters + in-flight booleans for cancellation
- Per-thread DispatchQueue.main.async hops + serial queue access patterns

### 5.2 Rewrite Concurrency Guarantees

- **@MainActor @Observable stores** — all property reads/writes on main thread, guaranteed by compiler
- **Actor services** (PersistenceActor, FileIndexActor, SessionBindingActor, RenderHostClient) — I/O off main
- **AsyncStream event sources** — consumed in plain Tasks (cancellation replaces generation counters)
- **No @unchecked Sendable** in new code

### 5.3 View Synchronization

- @Observable property changes automatically invalidate dependent views (per-property granularity)
- No manual didSet triggers; publishers only where async work is needed
- Example: `@Environment(\.appTheme)` + `.onChange(of:)` on theme name → theme recomputation

---

## 6. Hot-Reload Contract (Rendering Changes Without Restart)

**Trigger:** SettingsWindowView theme/font picker change OR SystemAppearanceObserver system appearance flip

**For terminal surfaces (Chunk D):**
1. RenderHostClient detects rendering config change (theme ID, font family, font size, ligatures)
2. Sends `setRendering(config: TerminalRenderingConfig)` XPC message to helper
3. Helper updates Ghostty surface render state WITHOUT restarting PTY
4. New frames render with updated theme/font, displayed via IOSurface update

**For editor surfaces:**
- SwiftUI automatically re-renders with new font/color from @Environment

**For UI (sidebar, etc.):**
- Dracula color lookups happen in view body; theme change invalidates all views (draculaColor change propagates)

---

## 7. Key Implementation Files (Port-From References)

| Source File | Lines | Content | Disposition |
|-------------|-------|---------|-------------|
| RootView.swift | 1–2262 | Root view tree, chrome toolbar, sidebar, main workspace, right panel | Port as thin consumers (delete 90% business logic, keep structure) |
| WorkspaceSplitView.swift | 1–705 | AppKit split-view controller + dividers + material handling | Keep largely as-is (no logic change) |
| WorkspaceSupportViews.swift | 1–261 | Terminal placeholder, bottom bar, collapsed rail, title updater | Keep placeholder structure; Chunk D replaces IsolatedAgentTerminalView |
| ChromeMetrics.swift | 1–70 | Token constants + icon button | Keep verbatim |
| FileBrowserPanelView.swift | 1–413 | Files tab UI + search + tree display | Port as thin consumer of RightPanelStore + FileIndexActor events |
| ThreadChoiceSheet.swift | 1–315 | New thread creation modal + agent grid + options | Port with error handling as visible ActivityStore state |
| SettingsWindowView.swift | 1–164 | Settings window structure + sidebar material | Keep tabs + navigation; Chunk E provides SettingsStore |
| GeneralSettingsView.swift | 1–86 | General pane (default agent, build info) | Port w/ SettingsStore bindings |
| AppearanceSettingsView.swift | 1–224 | Theme + font pickers + ligatures toggle | Port w/ SettingsStore bindings |
| KeyboardShortcutsSettingsView.swift | ? | Keyboard shortcut editor | Port w/ SettingsStore binding |
| YAAWApp.swift | 1–753 | Singleton + delegate + command menus + settings window | Keep duplicateInstanceSweep + titlebar; Chunk E wires stores |

---

## 8. Acceptance Tests (Parity Spec)

**All driven by Chunk G E2E harness; all cited from existing tests or behavior assertions:**

### 8.1 Feature Parity Probes (from Feature-Parity Inventory, Master Plan §Feature-parity)

1. **Projects:** create/select/pin/archive/expand/collapse all via UI + keyboard shortcuts
2. **Threads:** create/select/pin/archive/rename via UI + keyboard shortcuts; display name from metadata or user name
3. **Sidebar:** trees + search scopes; context menus; hover-only actions; 0 focus steal
4. **Right panel:** files/browser/nvim/git tabs + tab-switching + search + preview
5. **Layout:** resizable sidebar/right/bottom with proper min/max; collapse icons + toggle buttons
6. **Keyboard shortcuts:** all ~40 actions configurable; settable to empty (unbound); duplicate detection; restore defaults
7. **Activity/notifications:** unread dots appear; system notifications + dock badge when focused thread gets input; sanitized previews

### 8.2 Appearance Parity (from Appearance-parity § checklist)

**Screenshot diff baseline:** `docs/examples/screenshots/current/*`

1. **Native titlebar toolbar:** unifiedCompact style, no custom chrome, SF Symbols render at native weight/size
2. **Sidebar material:** behindWindow `.sidebar` material + theme tint overlay visible; reduce-transparency flips to opaque tint
3. **Settings window + sheets:** same material treatment (glass effect); no outline/border artifacts
4. **Theme switching:** live color change on all UI (text, backgrounds, dividers); no visual jank/flicker
5. **Font switching:** interface/editor/terminal fonts + sizes apply live; ligatures toggle reflects in editor + terminal (verified via Chunk D hot-reload)
6. **System appearance following:** light→dark flip triggers theme pair recomputation; system light/dark themes render correctly
7. **Dracula + built-ins:** Dracula colors pixel-perfect; other themes render without unsupported-theme diagnostics

### 8.3 Accessibility Identifiers (new in Chunk F)

**All interactive controls must have stable `accessibilityIdentifier`:**

- Toolbar buttons: "toggle-sidebar-button", "navigate-back-button", etc.
- Sidebar buttons: project/thread buttons, +New button, menu items
- Right panel tabs: "right-panel-tab-files", "right-panel-tab-browser", etc.
- Settings sidebar: "settings-sidebar-[section]" per section
- Settings controls: "settings-theme-picker", "settings-font-ligatures-toggle", etc.
- Pane views: "project-terminal", "bottom-terminal", "files-panel", etc.

**Test hook:** E2E uses `mcp__claude-in-chrome__find` or similar to locate controls by AX ID, verify visibility + enabled state

### 8.4 Single-Instance Sweep (per YAAWApp.init, lines 31–47)

1. Launch app twice from different install paths (`/Applications/YAAW.app` + `/Users/you/builds/YAAW.app`)
2. Verify older instance SIGTERM'd (within 3s) or forceTerminate'd
3. Verify new instance' terminals never show orphaned panes from killed instance

### 8.5 Keyboard Shortcut Binding Tests

**From KeyboardShortcutEventMatchingTests.swift (referenced):**

- Cmd+[ / Cmd+] navigate back/forward (history stack)
- Cmd+1/2/3 switch right panel modes (files/git/nvim)
- Cmd+, opens settings window
- Cmd+J toggles bottom terminal
- Cmd+B toggles sidebar
- Cmd+' toggles right panel
- Cmd+O / Cmd+Shift+O open selected dir/file externally
- All shortcuts routed through `handleForwardedTerminalShortcut` (no terminal focus required)

---

## 9. Risks & Mitigations (Chunk F-specific)

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Appearance regress on theme/font hotswap | Medium | Screenshot-diff gate before merge; verify @Observable invalidation works per-property |
| Accessibility IDs unstable across refactor | Low | Use stable enum-based identifiers; test via AX tree in E2E |
| Keyboard shortcut forwarding loses edge cases | Medium | Full forwarded-shortcut test suite (IME, dead keys if in scope) |
| RenderHostClient integration lag (terminal not ready) | High (blocked by Chunk D) | Chunk D must implement frame-ready handshake + "reconnecting" state |
| SettingsStore hot-reload race (config edit mid-render) | Medium | Atomic YAML write + SettingsStore mutation under @MainActor |
| SidebarMaterialBackground reduce-transparency visual artifact | Low | Pre-render both material + opaque states in screenshot baseline |

---

## 10. Summary & Deliverables

**Chunk F produces:**
1. Thin SwiftUI views (SidebarView, MainWorkspaceView, RightPanelView, SettingsView + panes, TerminalSurfaceHostView placeholder)
2. All interactive controls + text fields with accessibilityIdentifier
3. Keyboard shortcut routing (terminal-forwarded + app-scope actions)
4. Theme/font hot-reload pipeline (store mutation → @Observable invalidation → view re-render)
5. Appearance pixel-faithful to current Dracula + materials (sidebar material, titled toolbar, glass sheets)
6. Acceptance tests passing (screenshot parity + AX tree stable + shortcuts functional + single-instance sweep + activity/notification pushes)

**Blockers:** Chunk E (store interfaces) must be frozen + Chunk D (RenderHostClient) must be far enough for placeholder integration.

**Tightest coupling:** RootView ↔ AppEnvironment (constructor injection); each feature view reads exactly one store (no god object).
