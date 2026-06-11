# Test Inventory & Port Specification

**Purpose:** Cross-cutting spec for all existing tests under `src/Tests/YAAWKitTests`, `src/Tests/YAAWKitBenchmarks`, and `src/Tests/YAAWToolHostSupportTests`. Maps each test file to the rewrite chunk that owns it, identifies pure behavior tests that port verbatim vs. internals-coupled tests that need re-pointing, and locks benchmark perf targets.

---

## Summary Statistics

- **Total test files:** 17
- **Total unit tests:** 354
- **Total benchmark tests:** 34 (behind `RUN_BENCHMARKS=1`)
- **Total lines of test code:** ~10,374
- **Test coverage:** Behavior-level (value tests, protocol conformance, UI state transitions) + internals (concurrency, serialization, file I/O).

---

## Test Files by Chunk

### **Chunk 0 — Domain Port (Low-Risk, Behavior-Level)**

Tests in this section exercise value types and configurations that port largely as-is, with zero structural coupling to the god-object or old concurrency patterns.

#### **ProjectThreadModelTests.swift**
- **Location:** `src/Tests/YAAWKitTests/ProjectThreadModelTests.swift`
- **XCTestCase:** `ProjectThreadModelTests`
- **Test count:** 2
- **What it locks:** Public API of `Project` and `AgentThread` value types
  - `testProjectPreservesPublicMetadata` — validates Project properties: id, displayName, rootDirectory, createdAt, lastOpenedAt, isPinned, sortOrder
  - `testAgentThreadPreservesPublicMetadataAndArchiveState` — validates AgentThread properties: id, displayName, projectID, workingDirectory, createdAt, lastOpenedAt, isArchived, isPinned
- **Port category:** Pure behavior / value test — **port verbatim**, no refactoring needed
- **Chunk owner:** **Chunk 0 (domain port)**

#### **DraculaThemeTests.swift**
- **Location:** `src/Tests/YAAWKitTests/DraculaThemeTests.swift`
- **XCTestCase:** `DraculaThemeTests`
- **Test count:** 13
- **What it locks:** Theme catalog, color tokens, ANSI palette, contrast ratio, material tint opacity, appearance following
  - `testThemeCatalogExposesSupportedThemesWithGhosttyDefault` — catalog IDs, default light/dark, current theme = "ghostty-default"
  - `testEveryBuiltInThemeHasRequiredValidHexTokens` — all 16 themes have valid 7-char hex colors for all ThemeRole enum cases
  - `testEveryBuiltInThemeExposesTerminalANSIPalette` — 16-color ANSI palette present and valid hex
  - `testEveryBuiltInThemeExposesValidUIColors` — all ThemeUIRole colors valid (secondaryLabel, tertiaryLabel, etc.)
  - `testPreferredColorSchemeFollowsThemeGroup` — Dracula/dark-* return .dark, light-* return .light
  - `testDraculaSecondaryUILabelMeetsTextContrast` — contrast ratio ≥ 4.5
  - `testDraculaThemeExposesExpectedInitialTokens` — exact hex values for 11 token roles
  - `testDraculaTerminalANSIPaletteMatchesCanonicalTerminalColors` — exact 16-color array (incl. "#21222c" for black)
  - `testMacOSThemesExposeAppleSystemTokens` — macos-light/dark exact foreground/background/comment hex
  - `testMacOSThemesExposeExplicitANSIPalettes` — exact palette arrays for light/dark
  - `testMacOSThemesMeetTextContrast` — both macOS themes ≥ 7 contrast foreground/background, ≥ 4.5 secondaryLabel/background
  - `testMaterialTintFollowsThemeKind` — light/dark prefersSystemMaterials=true, materialTintOpacity=0.7; dracula/high-contrast tint behavior
  - `testGhosttyDefaultKeepsExplicitANSIPalette` — first="#1d1f21", last="#eaeaea", count=16
- **Port category:** Pure appearance token test — **port verbatim**, no refactoring
- **Chunk owner:** **Chunk 0 (domain port)**

#### **BundledFontCatalogTests.swift**
- **Location:** `src/Tests/YAAWKitTests/BundledFontCatalogTests.swift`
- **XCTestCase:** `BundledFontCatalogTests`
- **Test count:** 3
- **What it locks:** Font registration, JetBrains Mono availability, idempotency, face coverage
  - `testRegisterBundledFontsMakesJetBrainsMonoResolvable` — CTFont lookup for "JetBrainsMono-Regular", family matches catalog constant
  - `testRegisterBundledFontsIsIdempotent` — multiple calls succeed
  - `testBundledFacesCoverEditorAndTerminalWeights` — 6 faces registered: Regular, Italic, Medium, SemiBold, Bold, BoldItalic
- **Port category:** Pure font registration test — **port verbatim**
- **Chunk owner:** **Chunk 0 (domain port)**

#### **IconSystemTests.swift**
- **Location:** `src/Tests/YAAWKitTests/IconSystemTests.swift`
- **XCTestCase:** `IconSystemTests`
- **Test count:** 8
- **What it locks:** Icon resolution rules, bundled asset IDs, system symbol names, agent CLI brand icons
  - `testFileIconResolverPrefersExactFilenameThenExtension` — Package.swift → "material-file-icons/swift", package.json → "material-file-icons/package"
  - `testFileIconResolverUsesCompoundExtensionsBeforeExtensions` — App.test.ts → typescript, types.d.ts → typescript, App.module.css → css
  - `testFileIconResolverUsesExtensionFallback` — .swift → swift, .yml → yaml
  - `testFileIconResolverUsesFolderNamesAndOpenFolderFallback` — src closed → "material-file-icons/src-folder", expanded → "open-folder", unknown → "folder"
  - `testFileIconResolverUsesGenericFileFallback` — unknown.blob → "material-file-icons/file"
  - `testFileIconResolverKeepsSelectedPackInAssetIDs` — catppuccin pack changes prefix
  - `testNativeIconRolesResolveToSystemSymbols` — settings → "gearshape", installUpdate → "arrow.down.circle", etc. (6 assertions)
  - `testAgentCLIKindsExposeBrandIconResourceNamesAndFallbackSymbols` — codex/claude/opencode/copilot have PNG brand icons + non-empty fallback symbols
- **Port category:** Pure icon resolution test — **port verbatim**
- **Chunk owner:** **Chunk 0 (domain port)**

#### **RightPanelModeTests.swift**
- **Location:** `src/Tests/YAAWKitTests/RightPanelModeTests.swift`
- **XCTestCase:** `RightPanelModeTests`
- **Test count:** 9
- **What it locks:** RightPanelMode cycling, RightPanelTab title generation, tab lifecycle (open/close/fallback), pinned tab enforcement, per-mode state
  - `testRightPanelModeCyclesForwardInRequiredOrder` — files→browser→git→nvim→files
  - `testRightPanelModeCyclesBackwardInRequiredOrder` — files←nvim←git←browser←files
  - `testNvimTabTitleUsesOpenedFileName` — "docs/user-guide/README.md" → title "README.md"
  - `testBrowserTabTitleUsesReadableShortURL` — HTTPS URL with query → "example.com/docs/user-guide"
  - `testBrowserTabTitleUsesPreviewFileName` — file:// with relativePath → "index.html"
  - `testClosingSelectedNvimTabFallsBackToDefaultNvimTab` — close nvim tab → selectedTabID → RightPanelTab.defaultNvimID
  - `testClosingSelectedBrowserTabFallsBackToNearestBrowserTab` — close first of two browser tabs → selection → second tab
  - `testPinnedRightPanelTabsCannotBeClosed` — attempt to close filesID, defaultBrowserID, gitID, defaultNvimID → nil return
  - `testClosingUnselectedTabKeepsCurrentSelection` — close unselected → selectedTabID unchanged
- **Port category:** Pure state machine / value test — **port verbatim**
- **Chunk owner:** **Chunk 0 (domain port)**

#### **KeyboardShortcutEventMatchingTests.swift**
- **Location:** `src/Tests/YAAWKitTests/KeyboardShortcutEventMatchingTests.swift`
- **XCTestCase:** `KeyboardShortcutEventMatchingTests`
- **Test count:** 4
- **What it locks:** Keyboard event matching, default shortcuts, unbound/duplicate detection, modifier handling
  - `testCommandShortcutMatchesDefaultAction` — Cmd+J matches toggleBottomTerminal, not openSettings
  - `testShiftedPunctuationMatchesCharactersIgnoringModifiers` — Cmd+Shift+[ matches previousRightPanelMode
  - `testCommandVDoesNotMatchAnyDefaultYAAWShortcut` — Cmd+V reserved for paste
  - `testAppModelDisablesUnboundAndDuplicateShortcuts` — toggle unbound → disabled, set refreshFiles to same key as reloadSettings → both disabled
- **Port category:** Event matching behavior — **port verbatim**, though will need re-pointing to new store API in AppModelTests context
- **Chunk owner:** **Chunk 0 (domain port)** / **Chunk E (stores)**

#### **MarkdownPreviewTests.swift**
- **Location:** `src/Tests/YAAWKitTests/MarkdownPreviewTests.swift`
- **XCTestCase:** `MarkdownPreviewTests`
- **Test count:** 3
- **What it locks:** Markdown→HTML rendering, Mermaid diagram support, XSS sanitization, URL detection
  - `testRendererBuildsHTMLForMarkdownAndMermaid` — H1 ID anchors, link hrefs, mermaid-card divs, CSP headers present
  - `testRendererSanitizesUnsafeHTML` — script tags removed, javascript: URLs removed, onclick removed, `<strong>` preserved
  - `testMarkdownURLDetectionIsCaseInsensitiveForFileURLs` — file:///tmp/README.MD, .markdown match; .html and https:// don't
- **Port category:** Pure HTML generation test — **port verbatim**
- **Chunk owner:** **Chunk 0 (domain port)**

#### **ExternalOpenTests.swift**
- **Location:** `src/Tests/YAAWKitTests/ExternalOpenTests.swift`
- **XCTestCase:** `ExternalOpenTests`
- **Test count:** 7
- **What it locks:** Tool resolution order, default tool fallback, editor-only filtering, Finder/Terminal special handling, URL routing
  - `testAvailableToolsFollowPreferredOrderAndIgnoreMissingTools` — preferred=[webstorm, zed, finder, vscode], detected=[finder, vscode, zed] → [zed, finder, vscode]
  - `testConfiguredDefaultWinsWhenAvailable` — configured default "zed" chosen if available
  - `testMissingConfiguredDefaultFallsBackToFirstAvailableTool` — default missing → first of available
  - `testDefaultEditorToolFiltersFinderAndTerminalDestinations` — editor tools exclude Finder, Terminal; Finder fallback if no editors available
  - `testFileTargetsRouteTerminalAppsToContainingDirectory` — file → zed opens file; terminal → directory
  - `testDirectoryTargetsRouteAllToolsToDirectory` — directory target → all tools receive directory
- **Port category:** Pure tool resolution logic — **port verbatim**
- **Chunk owner:** **Chunk 0 (domain port)**

---

### **Chunk A — PersistenceActor (SQLite + State)**

Tests exercising SQLite migration, schema evolution, WAL mode, UPSERT, persistence ops.

#### **PersistenceTests.swift**
- **Location:** `src/Tests/YAAWKitTests/PersistenceTests.swift`
- **XCTestCase:** `PersistenceTests`
- **Test count:** 56
- **Key test groups:**
  - **Schema migration** (9 tests) — init, WAL mode check, partial v0 recovery, v1→v2 (agent_cli add), v1 rejection without agent_cli, v3+ migrations (pending_session_rename, launch_options_json, right_panel_state)
  - **Migration failure handling** (4 tests) — schema mismatch rejection with diagnostic event
  - **Load/save roundtrip** (5 tests) — save and reload matches
  - **Incremental updates** (6 tests) — upsertThread, upsertProject, upsertActivity per-row correctness
  - **Concurrency / transactions** (3 tests) — concurrent load/save safety
  - **Edge cases** (5 tests) — null handling, cascade deletes, empty snapshots
  - **Activity indexing** (3 tests) — activity queries, archive filtering
  - **Right-panel state persistence** (4 tests) — per-thread mode/tab state round-trip
  - **Diagnostic recording** (2 tests) — WAL failure events, migration error events
- **Port category:** MIXED
  - **Behavior-level (pass verbatim):** schema version checks, WAL mode, cascade delete semantics, load/save round-trip correctness, migration ladder logic
  - **Internals-coupled (re-point):** internal statement preparation, transaction isolation (will move to actor boundaries; tests may use fakes or spy on actor calls)
- **Acceptance gates (Chunk A):**
  - Migration v16→v17 passes with no data loss
  - Load @10k ≤ 10 ms, save @10k ≤ 30 ms (was 381 ms)
  - WAL enabled and readable
  - No metadata written to user dirs
- **Chunk owner:** **Chunk A (PersistenceActor)**

#### **SQLitePersistenceBenchmarks.swift**
- **Location:** `src/Tests/YAAWKitBenchmarks/SQLitePersistenceBenchmarks.swift`
- **BenchmarkCase:** `SQLitePersistenceBenchmarks`
- **Benchmark count:** 7 (behind `RUN_BENCHMARKS=1`)
- **Perf targets (locked by plan Chunk A):**
  - `test_bench_save_100threads` — measure store.save() on 100-thread snapshot
  - `test_bench_save_1k_threads` — 1,000 threads
  - `test_bench_save_10k_threads` — **10,000 threads target: ≤ 30 ms** (was 381 ms full DELETE+INSERT; now UPSERT)
  - `test_bench_load_100threads` — measure store.load()
  - `test_bench_load_1k_threads`
  - `test_bench_load_10k_threads` — **target: ≤ 10 ms** (index scan + parsing)
  - `test_bench_save_singleThreadEdit_in10kCorpus` — **target: ≤ 2 ms** (single upsertThread call on existing corpus; preserve from post-merge perf doc)
- **Metric:** XCTClockMetric (wall-clock time)
- **Port category:** Benchmark targets → **re-point to actor-based API once PersistenceActor available; perf gates unchanged**
- **Chunk owner:** **Chunk A (PersistenceActor)**

---

### **Chunk B — FileIndexActor (Walk, Cache, Fuzzy Search)**

Tests exercising file traversal, ignore rules, fuzzy matching, tree building, visible-row limiting.

#### **FileBrowserTests.swift**
- **Location:** `src/Tests/YAAWKitTests/FileBrowserTests.swift`
- **XCTestCase:** `FileBrowserTests`
- **Test count:** 32
- **Key test groups:**
  - **Ignore rules** (3 tests) — default rules skip .git, node_modules, worktrees; keep hidden files, .env, .build
  - **Path normalization** (3 tests) — relative path extraction, separator collapsing, rule whitespace trimming
  - **Fuzzy matching & ranking** (4 tests) — exact filename preference, prefix preference, fuzzy matching, path ranking (README vs r/e/a/d/m/e)
  - **Visible-row limiting** (3 tests) — capped results with overflow count, large-directory handling (25k entries)
  - **Tree building & expansion** (5 tests) — visible rows from collapsed/expanded folders, subtree merging, children index
  - **Symbol deduplication** (2 tests) — git-linked files/dirs not duplicated
  - **Large-index performance** (3 tests) — 50k+ entry indexing, lazy expansion without re-sort
  - **Search result state** (4 tests) — isLimitApplied flag, totalMatches count
- **Port category:** Pure behavior-level, no internals coupling
  - **All tests port verbatim** — ignore rules, fuzzy algo, tree structure are stateless
- **Acceptance gates (Chunk B):**
  - Fuzzy 50k/3-char ≤ 400 ms (debounced; baseline 916 ms uncapped)
  - Tree builder 50k ≤ 61 ms
  - Cold index 50k ≤ 1.5 s
- **Chunk owner:** **Chunk B (FileIndexActor)**

#### **FuzzyMatcherBenchmarks.swift**
- **Location:** `src/Tests/YAAWKitBenchmarks/FuzzyMatcherBenchmarks.swift`
- **BenchmarkCase:** `FuzzyMatcherBenchmarks`
- **Benchmark count:** 6
- **Perf targets (locked by plan Chunk B):**
  - `test_bench_fuzzy_5k_singleChar` — measure FuzzyFileMatcher.rankedEntries(5k, "s")
  - `test_bench_fuzzy_5k_threeChar` — measure FuzzyFileMatcher.rankedEntries(5k, "swi")
  - `test_bench_fuzzy_5k_eightChar` — measure FuzzyFileMatcher.rankedEntries(5k, "scenario")
  - `test_bench_fuzzy_50k_threeChar` — measure uncapped rank over 50k entries
  - `test_bench_fuzzy_50k_cappedThreeChar` — **target: ≤ 400 ms** for rankedResult(50k, "swi", limit=1000)
  - `test_bench_fuzzy_150k_cappedThreeChar` — **target: ≤ 400 ms** capped results on 150k corpus (real-world large repo)
- **Metric:** XCTClockMetric
- **Port category:** Algorithm benchmark → **port verbatim**, perf targets unchanged
- **Chunk owner:** **Chunk B (FileIndexActor)**

#### **FileIndexerBenchmarks.swift**
- **Location:** `src/Tests/YAAWKitBenchmarks/FileIndexerBenchmarks.swift`
- **BenchmarkCase:** `FileIndexerBenchmarks`
- **Benchmark count:** 3
- **Perf targets (locked by plan Chunk B):**
  - `test_bench_index_smallRepo` — 100 files, 10 dirs → cold-index baseline (< 10 ms typical)
  - `test_bench_index_mediumRepo` — 5k files, 200 dirs → **target: no regression** (benchmark baseline)
  - `test_bench_index_largeRepo` — 50k files, 2k dirs + ignored dirs → **target: ≤ 1.5 s** (with .git, node_modules ignored)
- **Metric:** XCTClockMetric
- **Port category:** Walk-performance benchmark → **port verbatim**, perf gates unchanged
- **Chunk owner:** **Chunk B (FileIndexActor)**

#### **TreeBuilderBenchmarks.swift**
- **Location:** `src/Tests/YAAWKitBenchmarks/TreeBuilderBenchmarks.swift`
- **BenchmarkCase:** `TreeBuilderBenchmarks`
- **Benchmark count:** 10
- **Perf targets (locked by plan Chunk B):**
  - `test_bench_treeBuilder_5k` → baseline
  - `test_bench_treeBuilder_50k` → **target: ≤ 61 ms** building roots/index from flat entry array
  - `test_bench_visibleRows_50k_collapsed` → **target: < 10 ms** (no expansions)
  - `test_bench_visibleRows_50k_oneExpandedBranch` → **target: < 50 ms** (src + src/core expanded)
  - `test_bench_visibleRows_150k_collapsed` → **target: < 10 ms**
  - `test_bench_visibleRows_150k_oneExpandedBranch` → **target: < 50 ms**
  - `test_bench_visibleRows_150k_cappedTenThousandRows` → **target: < 200 ms** (all folders expanded, row limit applied)
  - `test_bench_childrenIndex_150k` → **target: < 200 ms** one-time index build
  - `test_bench_visibleRows_index_150k_oneExpandedBranch` → **target: < 50 ms** walk prebuilt index (independent of total size)
  - `test_bench_visibleRows_index_150k_directoryHeavy` → **target: < 100 ms** (120k dirs / 30k files stress test)
- **Metric:** XCTClockMetric
- **Port category:** Algorithm benchmark → **port verbatim**
- **Chunk owner:** **Chunk B (FileIndexActor)**

---

### **Chunk C — SessionBindingActor (CLI Adapters, Manifests)**

Tests exercising CLI command construction, option parsing, session resumption, manifest conformance.

#### **AgentCLIAdapterTests.swift**
- **Location:** `src/Tests/YAAWKitTests/AgentCLIAdapterTests.swift`
- **XCTestCase:** `AgentCLIAdapterTests`
- **Test count:** 34
- **Key test groups:**
  - **Resume command construction** (3 tests) — stored session identity used for codex/claude/copilot/opencode resume flags
  - **Launch option precedence** (5 tests) — permission mode + additional args prepended before resume; unsupported modes per family ignored
  - **Option argument parsing** (3 tests) — quote/escape handling, unclosed-quote rejection
  - **Missing executable fallback** (2 tests) — command name used in error output if executable not found
  - **Path encoding** (4 tests) — shell escaping, quote safety, environment variable substitution
  - **Help text parsing** (6 tests) — extract permission presets from --help output per CLI family
  - **Capture log paths** (3 tests) — capture log URL plumbed through, max bytes parsed
  - **Environment variable injection** (2 tests) — YAAW_EVENT_LOG, TERM, PATH assembly
  - **Fixture-based conformance** (4 tests) — recorded claude/codex help text → correct preset extraction
- **Port category:** MIXED
  - **Behavior-level (port verbatim):** quote/escape, preset extraction, command assembly
  - **Internals-coupled (re-point):** executor resolver, session catalog lookup → will move behind SessionBindingActor; tests may mock
- **Acceptance gates (Chunk C):**
  - All four CLI families resume correctly from fixtures
  - Unsupported permission modes ignored per family
  - Manifest-driven (adding 5th CLI = manifest + fixtures, no new adapter class)
- **Chunk owner:** **Chunk C (SessionBindingActor)**

#### **AgentCLIOptionCatalogTests.swift**
- **Location:** `src/Tests/YAAWKitTests/AgentCLIOptionCatalogTests.swift`
- **XCTestCase:** `AgentCLIOptionCatalogTests`
- **Test count:** 4
- **What it locks:** Help-text parser → permission preset extraction per CLI
  - `testCodexHelpParserFindsApprovalSandboxAndBypassPresets` — codex --ask-for-approval modes + --sandbox modes + bypass
  - `testClaudeHelpParserFindsPermissionModePresets` — claude --permission-mode values (plan, auto, acceptEdits, dontAsk, bypassPermissions)
  - `testOpenCodeHelpParserFallsBackToCLIDefaultOnly` — opencode has no permission modes (empty preset list)
  - `testCopilotHelpParserFindsPermissionFlags` — copilot --plan, --autopilot, --allow-all-tools, --yolo
- **Port category:** Pure parser test — **port verbatim**
- **Chunk owner:** **Chunk C (SessionBindingActor)**

---

### **Chunk D — RenderHost + RenderHostClient (XPC, Input, Compositing)**

Tests exercising terminal output pumping, backpressure gate, input handling, protocol serialization, rendering state transitions.

#### **TerminalDriverTests.swift**
- **Location:** `src/Tests/YAAWKitTests/TerminalDriverTests.swift`
- **XCTestCase:** `TerminalDriverTests`
- **Test count:** 8
- **Key test groups:**
  - **Output pump batching** (3 tests) — adjacent output enqueued in single delivery; finish queued after output; large output chunked into size-limited batches
  - **Pump diagnostics** (2 tests) — slow delivery recorded with byte count; blocked delivery recorded (main actor not stalled)
  - **Operation driver serialization** (2 tests) — resize→write→terminate serialized via queue; duplicate resizes deduplicated; startup input delayed + sent through queue
  - **Launch failure handling** (1 test) — operation driver invokes onLaunchFailure callback
- **Port category:** Pure queue/pump behavior — **port verbatim**, no internals coupling
- **Chunk owner:** **Chunk D (RenderHost)**

#### **TerminalBackpressureGateTests.swift**
- **Location:** `src/Tests/YAAWKitTests/TerminalBackpressureGateTests.swift`
- **XCTestCase:** `TerminalBackpressureGateTests`
- **Test count:** 4
- **Key test groups:**
  - **High/low-water hysteresis** (1 test) — produced(600) on 1000 HWM → paused; consumed(500) → still paused; consumed(500) total on 250 LWM → resumed
  - **Block/unblock flow** (1 test) — waitUntilReadable() blocks until drained to low-water
  - **Close semantics** (1 test) — close() unblocks parked producer
  - **Concurrent produce/consume** (1 test) — 5000 iterations × 64 bytes with concurrent consumer → no bytes lost, no starvation
- **Constants locked:** highWaterMark = 1 MB (1,048,576), lowWaterMark = 256 KB (262,144)
- **Port category:** Pure synchronization test — **port verbatim**, behavior is unchanged
- **Chunk owner:** **Chunk D (RenderHost)**

#### **TerminalPasteTests.swift**
- **Location:** `src/Tests/YAAWKitTests/TerminalPasteTests.swift`
- **XCTestCase:** `TerminalPasteTests`
- **Test count:** 7
- **Key test groups:**
  - **Image paste policy** (2 tests) — all CLIs use native-attachment shortcut; no filesystem paths exposed
  - **Paste shortcut matching** (3 tests) — Return key not matched; Cmd+V and Ctrl+V matched; Cmd+Shift+V not matched
  - **Pasteboard extraction** (2 tests) — PNG data from pasteboard; PNG from file URL; RTFD attachment extraction
- **Port category:** Pure paste handling — **port verbatim**, behavior unchanged
- **Chunk owner:** **Chunk D (RenderHost)**

#### **IsolatedToolProtocolTests.swift**
- **Location:** `src/Tests/YAAWKitTests/IsolatedToolProtocolTests.swift`
- **XCTestCase:** `IsolatedToolProtocolTests`
- **Test count:** 13
- **Key test groups:**
  - **Envelope serialization** (2 tests) — Codable round-trip for versioned command envelope; version validation (reject unsupported)
  - **Browser state machine** (1 test) — launch → launching, ready → ready, stateChanged updates title/urlString/isLoading/canGo{Back,Forward}, crash → crashed/error
  - **Terminal launch construction** (2 tests) — from TerminalLaunchRequest, from AgentTerminalLaunchDescriptor; payload round-trip with command/environment/captureLogPath/startupInput/agentCLI
  - **Terminal launch validation** (1 test) — rejects empty command
  - **Launch transition classification** (4 tests) — between(nil, launch) → launchNew; between(launch, launch) → noChange; theme-only change → updateRendering (no process restart); ligatures toggle → updateRendering; process change → relaunchProcess
  - **Terminal exit tracking** (1 test) — exited(0) sets exitCode, relaunch clears it
  - **Rendering payload** (2 tests) — rendering payload round-trip; blank theme/font normalize to nil; ligatures default nil (enabled)
- **Port category:** MIXED
  - **Behavior-level (port verbatim):** enum state transitions, payload round-trip, launch vs. rendering identity
  - **Protocol-level (re-point):** will rewrite IsolatedToolEnvelope→YAAWRenderProtocol Codable envelopes; tests may be re-targeted to XPC-level serialization
- **Chunk owner:** **Chunk D (RenderHost + RenderHostClient)**

#### **TerminalHostRenderingConfigurationTests.swift**
- **Location:** `src/Tests/YAAWToolHostSupportTests/TerminalHostRenderingConfigurationTests.swift`
- **XCTestCase:** `TerminalHostRenderingConfigurationTests`
- **Test count:** 6
- **Key test groups:**
  - **Theme rendering** (2 tests) — Dracula colors render into Ghostty theme format; font-size/family in non-theme config; ligatures default to on (no font-feature output)
  - **Ligatures toggle** (1 test) — disabled → emits font-feature -calt/-liga/-dlig; absent → no font-feature lines
  - **Ghostty state adoption** (1 test) — theme applied even before OS dark-appearance adoption; state.effectiveColorScheme follows theme preference
  - **Fallback resolution** (1 test) — unknown theme → catalog default; nil font size → FontSettings().terminalSize
  - **Live update** (1 test) — state.setTheme() + state.setTerminalConfiguration() apply new config without view rebuild
  - **Appearance matching** (1 test) — dark theme → appKitAppearanceName=.darkAqua + swiftUIColorScheme=.dark; light → .aqua + .light
- **Port category:** Pure rendering config → **port verbatim**, config builder moves to YAAWRenderHost
- **Chunk owner:** **Chunk D (RenderHost)**

---

### **Chunk E — Stores + AppEnvironment (@MainActor @Observable)**

Tests exercising AppModel business logic: activity tracking, notification dispatch, unread counts, persistence coupling, thread/project selection, file browser state.

#### **AppModelTests.swift** (—major behavior spec)
- **Location:** `src/Tests/YAAWKitTests/AppModelTests.swift`
- **XCTestCase:** `AppModelTests`
- **Test count:** 126 (the largest single test file; behavior parity baseline for Chunk E)
- **Key test groups (representative sampling):**
  - **Thread activity inference** (5 tests) — relative time formatting (45s → "1m", 60m → "1h", etc.); status inference from terminal output ("Thinking..." → working, "Claude waiting" → needsInput, "Finished" → complete)
  - **Notification flow** (3 tests) — terminal notification → activity update + system notification dispatch; focused selected thread suppresses notification; generic notification preserves status
  - **Activity state transitions** (4 tests) — captured output clears stale "needsInput" preview; duplicate activity doesn't persist; duplicate read doesn't persist; unread count tracking
  - **Selection & navigation** (8 tests) — selectThread, selectProject, expand/collapse archive, project pin/sort
  - **Archive lifecycle** (5 tests) — archive thread, unarchive, archive project, section display
  - **Activity badges & preview** (6 tests) — unread count → system badge; previews rendered for notification context; title/body composited
  - **Right-panel state** (4 tests) — per-thread mode persistence, tab selection, tab close fallback
  - **File browser activation** (4 tests) — activateSelectedProjectTerminal loads file index; directory missing state; tool missing state
  - **External open integration** (3 tests) — externalOpenTarget constructs correct URL for tool
  - **Keyboard shortcut configuration** (3 tests) — shortcut enabled/disabled per definition, duplicate detection
  - **Activity re-rank** (2 tests) — file index subtree merge triggers re-ranking; visible rows capped + reflow
- **Port category:** **CRITICAL FOR CHUNK E**
  - **Behavior parity tests** (lock semantics): activity status inference, unread tracking, notification dispatch, selection, archive logic, file-browser activation — all **port verbatim** (re-point to new store APIs)
  - **Internals-coupled tests** (need re-pointing): generation counters, in-flight booleans → rewrite as Task cancellation patterns; per-thread activity index → rewrite as @Observable store lookup
- **Acceptance gates (Chunk E):**
  - Activity/title updates instant (event-pushed; no timers in idle)
  - Per-thread UI state survives relaunch (persisted in DB)
  - `activeThreadsForSelectedProject` reads ≤ 0.1 ms @10k (O(1) keyed lookup via ActivityStore selection)
- **Chunk owner:** **Chunk E (Stores + AppEnvironment)**

#### **AppModelBenchmarks.swift**
- **Location:** `src/Tests/YAAWKitBenchmarks/AppModelBenchmarks.swift`
- **BenchmarkCase:** `AppModelBenchmarks`
- **Benchmark count:** 8
- **Perf targets (locked by plan Chunk E):**
  - `test_bench_activeThreadsForSelectedProject_1k` → baseline
  - `test_bench_activeThreadsForSelectedProject_10k` — **target: ≤ 0.1 ms per 100k reads** (O(1) keyed lookup; preserve from post-merge doc)
  - `test_bench_selectedThread_lookup_10k` — **target: ≤ 0.1 ms per 100k reads**
  - `test_bench_selectThread_in_10kCorpus` — measure selectThread() latency (O(1) UUID set update)
  - `test_bench_selectThread_sqlite_in_1kCorpus` — measure with SQLite store (includes save path)
  - `test_bench_visibleThreadSwitch_warm_cachedIndex` — switch thread + activate terminal + visible rows with warm cached index → **p95 ≤ 250 ms**
  - `test_bench_visibleThreadSwitch_cold_noCachedIndex` — same without preseed (triggers index build) → measure baseline
  - `test_bench_duplicateActivity_in_10kCorpus` — 10k iterations of duplicate activity record (should dedup) → measure throughput
- **Metric:** XCTClockMetric
- **Port category:** Benchmark targets → **re-point to new store APIs once Stores available; perf gates unchanged**
- **Chunk owner:** **Chunk E (Stores + AppEnvironment)**

---

### **Chunk F — Feature Views + Appearance (Thin SwiftUI, AX IDs)**

Feature views port tests (appearance parity, interactive behavior).

**Tests owned by Chunk F** (not separate inventory — inherit from Chunk 0/A/B/C/D/E; F adds AX identifier coverage):
- `DraculaThemeTests` — theme appearance (Chunk 0, but F verifies applied live)
- `IconSystemTests` — icon resolution (Chunk 0)
- `KeyboardShortcutEventMatchingTests` — shortcut matching (Chunk E stores)
- `MarkdownPreviewTests` — HTML rendering (Chunk 0)
- `ExternalOpenTests` — tool routing (Chunk 0)

**No standalone Chunk F test files** — Chunk F is implementation + acceptance via **screenshot parity** (E2E comparisons) + AX tree assertions (in Chunk G E2E suite).

- **Chunk owner:** **Chunk F (Feature views + appearance)** — consumes tests from prior chunks; verifies via E2E

---

### **Chunk G — E2E + Acceptance Harness**

**No isolated unit tests for Chunk G** — E2E harness defined in `src/E2E/` (not under `src/Tests/YAAW*Tests`; separate executable target).

Expected structure (to be implemented):
- **E2E driver commands:** screenshot, send-key, send-click, frontmost-check, kill-pid
- **Acceptance probes:** create project → thread → agent CLI → resume → panel ops → archive → relaunch
- **Crash-isolation probe:** kill render helper → assert app survives, siblings unaffected, killed pane recovers
- **Perf gate runner:** invoke benchmarks from all chunks, assert targets
- **Screenshot-parity comparison:** vs. `docs/examples/screenshots/current/*`

- **Chunk owner:** **Chunk G (E2E + acceptance harness)** — builds on all prior tests; runs full gate

---

## Port-From Reference Map

| Test File | Subsystem | Chunk | Port Strategy | Key File References |
|---|---|---|---|---|
| **ProjectThreadModelTests.swift** | Domain model (value types) | 0 | Port verbatim | `src/Projects/Project.swift`, `src/Threads/AgentThread.swift` |
| **DraculaThemeTests.swift** | Theme system | 0 | Port verbatim | `src/Theme/DraculaTheme.swift`, `src/Persistence/YAAWConfiguration.swift` |
| **BundledFontCatalogTests.swift** | Font management | 0 | Port verbatim | `src/Fonts/BundledFontCatalog.swift` |
| **IconSystemTests.swift** | Icon resolution | 0 | Port verbatim | `src/Icons/IconSystem.swift` |
| **RightPanelModeTests.swift** | UI state machine | 0 | Port verbatim | `src/RightPanel/RightPanelState.swift` |
| **KeyboardShortcutEventMatchingTests.swift** | Input handling | 0/E | Port verbatim (re-point store ref in last test) | `src/Core/KeyboardShortcutDefinition.swift`, `src/Persistence/YAAWConfiguration.swift` |
| **MarkdownPreviewTests.swift** | Markdown rendering | 0 | Port verbatim | `src/MarkdownPreview/MarkdownPreviewRenderer.swift` |
| **ExternalOpenTests.swift** | External tool integration | 0 | Port verbatim | `src/Core/ExternalOpen.swift` |
| **PersistenceTests.swift** | SQLite store + migration | A | Port verbatim (behavior); re-point internal API to PersistenceActor | `src/Persistence/SQLiteYAAWStore.swift` (~115-176 save logic, ~1063-1069 prepare) |
| **SQLitePersistenceBenchmarks.swift** | Perf gate | A | Re-point to actor API; perf targets unchanged | Store benchmark setup |
| **FileBrowserTests.swift** | File indexing | B | Port verbatim | `src/FileBrowser/FileIndexCache.swift`, `FileBrowserIndex.swift`, `FileBrowserTreeBuilder.swift` (~205-218 merge) |
| **FuzzyMatcherBenchmarks.swift** | Perf gate | B | Port verbatim | Fuzzy match algorithm |
| **FileIndexerBenchmarks.swift** | Perf gate | B | Port verbatim | Indexing algorithm |
| **TreeBuilderBenchmarks.swift** | Perf gate | B | Port verbatim | Tree-building algorithm |
| **AgentCLIAdapterTests.swift** | CLI session binding | C | Port behavior-level tests; re-point executor/catalog lookups to SessionBindingActor | `src/AgentCLI/AgentCLIAdapter.swift` (~139-317), `AgentCLISessionCatalog.swift` |
| **AgentCLIOptionCatalogTests.swift** | CLI help parsing | C | Port verbatim | Help-text parsing logic |
| **TerminalDriverTests.swift** | Terminal output pump | D | Port verbatim | `src/Terminal/AgentTerminalOutputPump.swift`, `AgentTerminalOperationDriver.swift` |
| **TerminalBackpressureGateTests.swift** | PTY backpressure | D | Port verbatim | `src/Terminal/TerminalBackpressureGate.swift` (constants: 1 MB HWM, 256 KB LWM) |
| **TerminalPasteTests.swift** | Terminal paste handling | D | Port verbatim | Terminal paste policy |
| **IsolatedToolProtocolTests.swift** | XPC protocol | D | Port behavior-level state transitions; re-point serialization to YAAWRenderProtocol | `src/Core/IsolatedToolProtocol.swift` |
| **TerminalHostRenderingConfigurationTests.swift** | Rendering config | D | Port verbatim (config builder moves to YAAWRenderHost) | `src/ToolHostSupport/TerminalHostRenderingConfiguration.swift` |
| **AppModelTests.swift** | Business logic (activity, selection, file browser) | E | Port behavior-level (activity inference, selection, archive logic); re-point generation counters + in-flight bools to Task cancellation | `src/Core/AppModel.swift` (main logic), `src/App/IsolatedToolRuntime.swift` |
| **AppModelBenchmarks.swift** | Perf gate | E | Re-point to store APIs; perf targets unchanged | AppModel benchmark setup |

---

## Concurrency Hazards & Re-Pointing Guide

### Chunk A: PersistenceTests → PersistenceActor

**Current pattern:**
```swift
let store = try SQLiteYAAWStore(databasePath: path)
let loaded = store.load()
store.save(snapshot)
```

**New pattern (Chunk A):**
```swift
let actor = PersistenceActor(databasePath: path)
let loaded = try await actor.load()
try await actor.save(snapshot)
try await actor.upsertThread(thread)  // new incremental API
```

**Test re-pointing:**
- Behavior tests (schema validation, round-trip) → mock or spy on actor calls
- Benchmarks → invoke actor methods; still measure wall-clock time

---

### Chunk B: FileIndexing → FileIndexActor

**Current pattern:**
```swift
let entries = try BackgroundFileIndexer.buildIndex(...)
let ranked = FuzzyFileMatcher.rankedEntries(entries, query: "readme")
```

**New pattern:**
- Algorithms (FileBrowserTreeBuilder, FuzzyFileMatcher) stay stateless → **no change**
- Index caching + watching moves behind FileIndexActor
- E2E: subscribe to async stream, collect entries

---

### Chunk C: AgentCLIAdapter → SessionBindingActor

**Current pattern:**
```swift
let service = AgentCLISessionBindingService(resolver: ..., captureDirectory: ...)
let command = service.terminalCommand(for: thread)
```

**New pattern:**
```swift
let actor = SessionBindingActor(...)
let command = try await actor.terminalCommand(for: thread)
```

**Adapter tests → re-point to mock resolver/catalog or spy on actor**

---

### Chunk D: IsolatedToolProtocol → YAAWRenderProtocol (XPC)

**Current pattern:**
```swift
let envelope = IsolatedToolEnvelope(...)
let json = try JSONEncoder().encode(envelope)
let decoded = try JSONDecoder().decode(IsolatedToolEnvelope.self, from: json)
```

**New pattern:**
```swift
// Still Codable for XPC transmission
let message = YAAWRenderProtocol.TerminalLaunchRequest(...)
// ... via NSXPCConnection
let response = YAAWRenderProtocol.FrameReady(...)
```

**Test re-pointing:**
- Payload round-trip tests → still work (Codable unchanged in principle)
- XPC-level tests (new) → use mock connection or in-process server

---

### Chunk E: AppModel → @MainActor Stores (WorkspaceStore, ActivityStore, etc.)

**Current pattern:**
```swift
class AppModel: ObservableObject {
    @Published var selectedThreadID: UUID?
    @Published var threadActivities: [UUID: ThreadActivity] = [:]
    private var activityUpdateTask: Task<Void, Never>?  // generation counter
    
    func recordAgentCLIOutput(...) {
        // mutate @Published + in-flight bool
    }
}
```

**New pattern:**
```swift
@MainActor @Observable final class ActivityStore {
    var threadActivities: [UUID: ThreadActivity] = [:]
    
    func recordAgentCLIOutput(...) async {
        // Task cancellation replaces generation counter
    }
}
```

**Test re-pointing for AppModelTests:**
- Activity inference tests → stay on ActivityStore
- Selection tests → stay on WorkspaceStore
- File-browser activation → stay on ActivityStore
- Notification dispatch → still mocked/recorded; called from actor
- Replace all `XCTAssertEqual(model.selectedThreadID, ...)` with `XCTAssertEqual(await workspace.selectedThreadID, ...)`
- Replace in-flight-bool checks with Task cancellation assertions (may become implicit in test structure)

---

## Summary Table: Port Decision by Test

| Test | Behavior | Internals | Decision | Chunk |
|---|---|---|---|---|
| ProjectThreadModelTests | ✓ | — | Port verbatim | 0 |
| DraculaThemeTests | ✓ | — | Port verbatim | 0 |
| BundledFontCatalogTests | ✓ | — | Port verbatim | 0 |
| IconSystemTests | ✓ | — | Port verbatim | 0 |
| RightPanelModeTests | ✓ | — | Port verbatim | 0 |
| KeyboardShortcutEventMatchingTests | ✓ | 1 ref | Port + re-point last test to store | 0/E |
| MarkdownPreviewTests | ✓ | — | Port verbatim | 0 |
| ExternalOpenTests | ✓ | — | Port verbatim | 0 |
| PersistenceTests | ✓ | ✓ | Port behavior; re-point internal calls to PersistenceActor | A |
| SQLitePersistenceBenchmarks | — | ✓ | Re-point to actor; perf targets unchanged | A |
| FileBrowserTests | ✓ | — | Port verbatim | B |
| FuzzyMatcherBenchmarks | — | — | Port verbatim | B |
| FileIndexerBenchmarks | — | — | Port verbatim | B |
| TreeBuilderBenchmarks | — | — | Port verbatim | B |
| AgentCLIAdapterTests | ✓ | ✓ | Port behavior; re-point executor/catalog to SessionBindingActor | C |
| AgentCLIOptionCatalogTests | ✓ | — | Port verbatim | C |
| TerminalDriverTests | ✓ | — | Port verbatim | D |
| TerminalBackpressureGateTests | ✓ | — | Port verbatim (constants locked) | D |
| TerminalPasteTests | ✓ | — | Port verbatim | D |
| IsolatedToolProtocolTests | ✓ | ✓ | Port state transitions; re-point serialization to YAAWRenderProtocol | D |
| TerminalHostRenderingConfigurationTests | ✓ | — | Port verbatim (config builder moves to YAAWRenderHost) | D |
| AppModelTests | ✓ | ✓ | Port behavior parity; re-point to new store APIs, replace generation counters with Task cancellation | E |
| AppModelBenchmarks | — | ✓ | Re-point to store APIs; perf targets unchanged | E |

---

## Top Porting Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| **AppModelTests.swift re-pointing scope** (126 tests × 2-3 store re-points each) | High | Batch test rewrites per store (WorkspaceStore, ActivityStore, etc.); use find-replace + local validation; run continuously during Chunk E |
| **Generation counter removal logic** (porting detection of "is this result still valid?") | High | Task cancellation is compiler-enforced; tests may need rewrite to assert "no second update after cancel" instead of "generation mismatch"; reference Chunk E plan text |
| **File index async stream consumption** (tests currently expect synchronous result) | Medium | Wrap blocking tests in Task/async; use expectation-based waits for stream events; benchmark perf targets unchanged |
| **XPC serialization round-trip tests** (IsolatedToolProtocolTests → YAAWRenderProtocol) | Medium | Codable structure preserved; add XPC-level tests separately; old tests likely still pass with protocol name change only |
| **Benchmark baseline drift** (SQLite UPSERT vs. DELETE+INSERT, tree-builder optimization) | Medium | Run baseline benchmarks on old code first, commit as reference; allow ±10 % tolerance in acceptance gates; re-baseline after Chunk A/B complete |
| **Test parallelization** (fixture directory cleanup, temp file leaks) | Low | BenchmarkSupport cleanup already present; ensure tearDown removes all temp directories; no global state in tests |

---

## Acceptance Criteria for Test Porting

✓ All 254 behavior tests pass on rewrite (port × behavior lock)
✓ All 34 benchmarks pass on rewrite with perf gates met (or documented exceptions)
✓ Zero new `@unchecked Sendable` in test support code (fakes, fixtures, recorders)
✓ No test files ported with suppressed swiftlint rules (inherit tightened thresholds)
✓ AppModelTests behavior parity verified (activity inference, selection, archive, notification dispatch unchanged)
✓ XPC protocol tests (IsolatedToolProtocolTests) verified against actual NSXPCConnection in E2E suite

