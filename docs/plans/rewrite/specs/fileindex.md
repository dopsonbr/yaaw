# FileIndexActor Port Specification (Chunk B)

## Overview

Move file walk/cache/fuzzy-search/watch operations behind a `FileIndexActor` conforming to the `FileIndexing` protocol. The actor will orchestrate directory enumeration, caching, lazy subtree expansion, visibility capping, file-system watching, and incremental re-ranking—all while maintaining parity with the existing behavior.

## Scope & Constraints

### Keep (Preserve Exactly)

1. **Durable shared cache** — keyed by: root path + git identity (branch/detached/nogit) + ignore rules fingerprint + schema version
2. **Deduplication** — concurrent refresh requests for the same cache key coalesce to one underlying indexing call
3. **Lazy pruned-subtree expansion** — ignored directories (node_modules, .git, etc.) show collapsed but are indexed on demand
4. **Capped visible rows** — presentation limit of **10,000 rows** for the tree walk (bounded by `maxBrowseEntries`)
5. **350 ms FSEvents debounce** — directory watcher coalesces changes before triggering refresh
6. **Fuzzy ranking algorithm** — exact filename match (rank 0) → filename prefix (1000+) → path prefix (2000+) → fuzzy gap-penalty (3000+)
7. **Depth-first pre-order sorting** — directories sort before files at each level, hidden names sort last
8. **Per-thread metadata** — separate `FileIndexMetadata` per thread with independent threadID fields

### Fix (Behavioral Changes)

1. **Replace full re-sort on merge** — `FileBrowserTreeBuilder.merging()` ~205-218 currently re-sorts entire list. Switch to **sorted insertion/merge** that maintains pre-order without full array re-sort (perf win; no functional change visible to UI).
2. **Session-cache `.git/HEAD` reads** — every index call currently reads `.git/HEAD` afresh. Cache per session (per `FileIndexActor` instance lifetime) or per-root-per-git-identity.
3. **Expose incremental re-rank** — move fuzzy re-ranking behind an `AsyncStream<[FileBrowserEntry]>` so UI updates appear instant (debounced at 350 ms if coalesced with FS changes).

### Delete (Remove Entirely)

None from the FileIndex subsystem itself; overlay/viewport/polling lives in Chunk D (RenderHost).

---

## Public API Surfaces

### `FileIndexing` Protocol (Port from `src/FileBrowser/FileBrowserIndex.swift:17-36`)

```swift
public protocol FileIndexing: AnyObject {
    func indexFiles(
        threadID: UUID,
        root: URL,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    )

    /// Indexes a single pruned subtree on demand. `relativeSubpath` is the path of
    /// the pruned directory relative to `root`. The returned entries (including the
    /// subtree root itself, un-pruned) use paths relative to `root`, so they can be
    /// merged directly into the full index.
    func indexSubtree(
        threadID: UUID,
        root: URL,
        relativeSubpath: String,
        ignoreRules: [String],
        completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
    )
}
```

### `FileIndexResult` (Port from `src/FileBrowser/FileBrowserIndex.swift:3-11`)

```swift
public struct FileIndexResult: Equatable, Sendable {
    public var entries: [FileBrowserEntry]
    public var metadata: FileIndexMetadata
}
```

### `FileBrowserEntry` (Port from `src/FileBrowser/FileBrowserEntry.swift:3-19`)

```swift
public struct FileBrowserEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let isDirectory: Bool
    public let isPruned: Bool  // collapsed ignored directory

    public init(relativePath: String, isDirectory: Bool, isPruned: Bool = false)
}
```

### `FileIndexMetadata` (Port from `src/FileBrowser/FileBrowserEntry.swift:21-61`)

```swift
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

    public init(...)
    public func forThread(_ threadID: UUID) -> FileIndexMetadata
}
```

### `FileIndexCacheKey` (Port from `src/FileBrowser/FileIndexCache.swift:83-123`)

```swift
public struct FileIndexCacheKey: Equatable, Sendable {
    public let value: String
    public let rootPath: String
    public let gitIdentity: String
    public let ignoreRulesFingerprint: String
    public let schemaVersion: Int

    public init(
        root: URL,
        ignoreRules: [String],
        gitIdentityResolver: any FileIndexGitIdentityResolving = FileIndexGitIdentityResolver(),
        schemaVersion: Int = FileIndexMetadata.currentSchemaVersion
    )
    
    public static func fingerprint(ignoreRules: [String]) -> String
}
```

### `FileIndexGitIdentity` (Port from `src/FileBrowser/FileIndexCache.swift:3-18`)

```swift
public enum FileIndexGitIdentity: Equatable, Sendable {
    case branch(String)
    case detached(String)
    case notRepository

    public var cacheComponent: String
}
```

### `FileIndexGitIdentityResolver` (Port from `src/FileBrowser/FileIndexCache.swift:24-81`)

Resolves `.git/HEAD` to branch/detached/nogit; handles git worktree gitdir references.

---

## `FileIndexActor` Design

### Initialization & Lifecycle

```swift
@globalActor
actor FileIndexActor {
    private let store: YAAWStore
    private let queue: DispatchQueue  // from BackgroundFileIndexer
    private let gitIdentityResolver: any FileIndexGitIdentityResolving
    private var inFlightByCacheKey: [String: [PendingFileIndexConsumer]] = [:]
    private var gitHeadCache: [String: FileIndexGitIdentity] = [:]  // NEW: session-cache per root
    private let directoryWatcher: FileIndexDirectoryWatcher

    init(store: YAAWStore, gitIdentityResolver: any FileIndexGitIdentityResolving = ...)
}
```

### Public Methods

```swift
// Compute a cache key (unchanged from FileIndexCacheCoordinator)
func cacheKey(root: URL, ignoreRules: [String]) -> FileIndexCacheKey

// Retrieve cached index if available
func cachedIndex(threadID: UUID, key: FileIndexCacheKey) -> FileIndexResult?

// Refresh full index; coalesce identical concurrent requests
func refreshIndex(
    threadID: UUID,
    root: URL,
    ignoreRules: [String],
    key: FileIndexCacheKey,
    completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
)

// Lazily index a pruned subtree; coalesce identical concurrent requests
func refreshSubtree(
    threadID: UUID,
    root: URL,
    relativeSubpath: String,
    ignoreRules: [String],
    key: FileIndexCacheKey,
    completion: @escaping @Sendable (Result<FileIndexResult, Error>) -> Void
)

// NEW: AsyncStream for incremental re-rank results
func rankEntries(
    entries: [FileBrowserEntry],
    query: String,
    limit: Int? = nil
) -> AsyncStream<[FileBrowserEntry]>

// NEW: Set of directories to watch; trigger callback on change
func watch(
    directories: Set<String>,
    onChange: @escaping @Sendable () -> Void
)

// Stop watching
func stopWatching()
```

---

## Key Constants & Thresholds

| Constant | Value | Source | Use |
|----------|-------|--------|-----|
| `maxBrowseEntries` | 10,000 | `AppModel.swift:19` | Cap for full index tree row walk |
| `maxSearchResults` | 1,000 | `AppModel.swift:18` | Cap for fuzzy search result limit |
| `FSEvents debounce` | 350 ms | `FileIndexDirectoryWatcher.swift:74` | Coalesce FS changes before callback |
| `largeIndexDiagnosticThreshold` | 50,000 | `AppModel.swift:20` | Log warning if index exceeds this |
| `schemaVersion` | 3 | `FileBrowserEntry.swift:22` | Current cache key schema |
| `git identity` cache | per-session | NEW | Cache per `FileIndexActor` lifetime |

---

## Concurrency Model

### Current (AppModel.swift, FileIndexCacheCoordinator)

- `FileIndexCacheCoordinator` uses `NSLock` to guard `inFlightByCacheKey` dictionary
- Completion callbacks posted back to `DispatchQueue.main.async`
- `BackgroundFileIndexer` uses concurrent `DispatchQueue(label:qos:.userInitiated, attributes:.concurrent)`
- No generation counters; no cancellation (Swift async/await not used)

### Rewrite Target (Swift 6 Strict Concurrency)

- `FileIndexActor` is the sole synchronization point; no `NSLock`, no `@unchecked Sendable`
- Completion callbacks become `AsyncStream` events (or remain closure-based for compatibility)
- Internal background work remains on a non-main queue (kept off main thread)
- All public types are `Sendable`; no `@unchecked`
- Result delivery is implicitly on the actor (caller responsible for hopping to main if needed)

### Hazard Fixes Required

1. **`FileIndexGitIdentityResolver.gitIdentity()` is synchronous file I/O** — if called on the actor directly, it will block. **Solution:** keep git identity resolution on the background queue; cache the result in `gitHeadCache[rootPath] = identity` to amortize repeated reads.
2. **`FileIndexDirectoryWatcher` is currently `@unchecked Sendable`** — rework it to be truly safe or use a wrapper that's safe within the actor boundary.
3. **Per-thread metadata forking** — `metadata.forThread(_:)` creates a copy with modified threadID; ensure this is correctly threadsafe (it's just value-type copying, so it's safe).

---

## Cache Key Computation

**Exact formula** (from `FileIndexCacheKey.init()` ~90-106):

```
cache_key = "file-index:v{schemaVersion}:{digest}"
digest = hash(root_path || git_identity || ignore_rules_fingerprint || "{schemaVersion}")
```

**Git identity** (from `FileIndexGitIdentityResolver.gitIdentity()` ~27-43):

1. Search upward for `.git` directory (or worktree gitdir reference)
2. Read `.git/HEAD` (raw; no trimming in tests)
3. If starts with `"ref: "` → `branch(String(head.dropFirst("ref: ".count)))`
4. Else if non-empty → `detached(head)` (the full commit hash)
5. Else → `notRepository`

**Ignore rules fingerprint** (from `FileIndexCacheKey.fingerprint()` ~109-113):

1. Normalize each rule via `FilePathNormalizer.normalizedRule()`
2. Filter empty strings
3. Sort lexicographically
4. Hash using FNV-1a 64-bit:
   - Initial `hash = 14_695_981_039_346_656_037`
   - For each unicode scalar: `hash ^= UInt64(scalar.value); hash &*= 1_099_511_628_211`
   - Return `String(hash, radix: 16)`

---

## Indexing Algorithms

### Full Index (BackgroundFileIndexer.buildIndex ~156-221)

1. Check root is a directory; throw `missingRoot` if not
2. Use `FileManager.enumerator(at:includingPropertiesForKeys:[.isDirectoryKey], options:[.skipsPackageDescendants])`
3. For each entry:
   - Get normalized relative path
   - Check `isDirectory`
   - If directory matches ignore rules: **append as pruned, call `skipDescendants()`, count `ignoredDirectoryCount`**
   - Else append un-pruned (or non-directory)
4. Sort all entries via `FileBrowserTreeBuilder.sortEntriesForTree()`
5. Return `FileIndexResult(entries, metadata)`

### Subtree Index (BackgroundFileIndexer.buildSubtreeIndex ~110-142)

1. Build index as if starting from `root/relativeSubpath` (re-apply ignore rules within subtree)
2. Re-prefix all entries back to root-relative paths via `reprefix(entries:under:)`
3. **Insert subtree root itself as un-pruned directory** at index 0
4. Re-sort entire result via `sortEntriesForTree`
5. Return entries

### Merge (FileBrowserTreeBuilder.merging ~205-218)

**Current (naive):**
```swift
// Remove old pruned placeholder and all descendants
let filtered = entries.filter { entry in
    entry.relativePath != prunedPath
        && !entry.relativePath.hasPrefix("\(prunedPath)/")
}
// Append new subtree
merged.append(contentsOf: subtree)
// Full re-sort
merged.sort(by: sortEntriesForTree)
```

**Rewrite (sorted insertion):**

For each subtree entry, binary-search position in filtered list and insert in-place, maintaining pre-order without re-sorting the entire array. **No functional change to result; perf improvement.**

---

## Sorting Algorithm

**`FileBrowserTreeBuilder.sortEntriesForTree()` ~220-253** — **depth-first pre-order**:

At the first diverging path component:
1. Hidden names (`.prefix`) sort after non-hidden (configurable: `.swiftlint:disable` or re-enable if needed)
2. Directories (isDirectory || has deeper components) sort before files
3. Then lexicographic via `localizedStandardCompare`

If all shared components match:
1. Fewer components (shorter path) sorts first
2. If same depth, directories before files
3. Else lexicographic

---

## Visible Row Walk

**`FileBrowserTreeBuilder.visibleRows()` ~106-137** (two variants):

1. **From entries** (old): filter entries checking ancestor expansion; cap at `limit`
2. **From children index** (new, perf): use prebuilt `[String: [FileBrowserEntry]]` map (built once per index via `childrenIndex()` ~84-98); depth-first recurse from root, emitting only expanded branches

**Children index** (~84-98): maps parent relative path (empty string = root) to its direct children. Built in O(n), then row walk is O(limit), not O(total entries).

---

## Fuzzy Ranking

**`FuzzyFileMatcher.rank()` ~354-370**:

```
filename = URL(fileURLWithPath: entry.relativePath).lastPathComponent.lowercased()
path = entry.relativePath.lowercased()

return:
  0                    if filename == query
  1000 + filename.count  if filename.hasPrefix(query)
  2000 + path.count      if path.hasPrefix(query)
  3000 + fuzzyScore      if fuzzyScore(...) != nil
  nil                  (no match)
```

**`fuzzyScore()` ~372-389** — gap-penalty algorithm:

```
For each char in query:
  - Find first occurrence in path starting from last match
  - Add distance from previous match (or start) to current match
  - Move search start forward
Return (gap_penalty + path.count)
```

**Limited result** (bounded heap ~397-457):

For large indexes, maintain a max-heap of size `limit` (worst-rank-first), inserting only if better than worst current entry. Final sort yields top-`limit` best matches.

---

## Directory Watcher

**`FileIndexDirectoryWatcher` ~10-85**:

### Behavior

- Watches a set of directories (root + expanded folders)
- Monitors each for `.write | .delete | .rename | .revoke` events
- Debounces with 350 ms work item; fires callback once per coalesced change burst

### Implementation

- `DispatchQueue` per instance (label: `"dev.dopsonbr.YAAW.file-index-watcher"`, QoS: `.utility`)
- `DispatchSourceFileSystemObject` per watched path
- Single debounce work item, re-scheduled on each event

### New in Rewrite

- Callable from actor (safe to call from non-main context)
- Callback closure remains `@Sendable`; can post back to actor

---

## Test Assertions & Parity Spec

### FileBrowserTests (src/Tests/YAAWKitTests/FileBrowserTests.swift)

| Test | Asserts |
|------|---------|
| `testDefaultIgnoreRulesSkipHeavyDirectoriesButKeepHiddenFiles` | `.git`, `node_modules`, `DerivedData`, `worktrees` are ignored; `.env` is not |
| `testPathNormalizationRemovesRootAndCollapsesSeparators` | Paths normalize to forward slashes; `./` and `\\` removed |
| `testFuzzyRankingPrefersExactFilenameThenPrefixThenFuzzyPath` | Exact filename (rank 0) > prefix (1000+) > fuzzy (3000+) |
| `testFuzzyRankingLimitedResultKeepsBestMatchesAndCountsAllMatches` | Limited result cap returns top-N + total match count + `isLimitApplied` flag |
| `testVisibleTreeRowsOnlyIncludeExpandedBranchesAndHonorLimit` | Collapsed tree shows only roots; expanded shows descendants; limit caps output |
| `testVisibleTreeRowsCapsExpandedLargeBranch` | 25k entries, 10k limit cap works |
| `testVisibleRowsRevealDeepFilesInLargeIndexWhenExpanded` | Deeply nested files appear when ancestors expanded (regression test for old 10k cutoff bug) |
| `testVisibleRowsViaChildrenIndexMatchEntryWalkOrdering` | Two visible-row paths (via entries vs via index) produce identical output |
| `testSortKeepsDeepDirectoryContentsAheadOfLaterRootSiblings` | Deep entries sort before later root siblings (e.g., `a/x` before `b/y`) |
| `testTemporaryDirectoryIndexUsesTreeOrderWithFilesNearParents` | Real FS: directories sort before their files |
| `testTemporaryDirectoryIndexShowsIgnoredDirectoriesButPrunesDescendants` | Ignored dirs marked pruned; descendants not eagerly indexed |
| `testIndexSubtreeReturnsDescendantsAndUnprunedRoot` | Subtree result includes root as un-pruned + prefixed descendants |
| `testTreeBuilderMergingReplacesPrunedNodeAndSortsInPreOrder` | Merge removes old pruned entry, inserts subtree, maintains pre-order |
| `testCacheKeyIncludesDirectoryBranchAndIgnoreRules` | Cache key differs per root, git branch, ignore rules |
| `testCacheCoordinatorDeduplicatesSameKeyRefreshesAndSharesResult` | Two concurrent refresh(root, rules) calls result in one indexing op; both get results (with independent threadID in metadata) |
| `testAppModelFileIndexingDoesNotBlockSelectionChanges` | Thread selection works while indexing in flight |
| `testAppModelShowsSharedCachedEntriesWhileRefreshIsInProgress` | Shows cached entries immediately; re-indexes in background |
| `testWarmThreadSwitchUsesBoundedCachedBrowseAndFullSearch` | Cached 12k entries; 10k presentation cap; fuzzy search still works on full 12k |
| `testAppModelDeduplicatesSameThreadIndexRefreshes` | Multiple `refreshSelectedFileBrowser()` calls coalesce to one indexing |
| `testExpandingPrunedDirectoryMergesLazySubtreeAndMakesItSearchable` | Expand triggers subtree index; merge persists; fuzzy now matches subtree files |
| `testExpandingDirectoryIgnoresNonPrunedAndDuplicateRequests` | Non-pruned dirs don't trigger lazy load; repeated expands coalesce |
| `testExpandedFoldersAreRememberedPerThreadAcrossSwitches` | Expansion state per thread, independent per thread |
| `testSelectedFileIsRememberedPerThreadAcrossSwitches` | Selected file per thread, independent per thread |
| `testReindexDoesNotStompRememberedSelectionThatIsNoLongerVisible` | Reindex removing selected file: remember selection (don't jump to first) |
| `testLazyExpandShowsAndClearsIndexingIndicator` | Expand → isIndexing=true; complete → isIndexing=false |
| `testLazyExpandClearsIndicatorOnFailure` | Error during expand → isIndexing=false |
| `testConcurrentExpandsKeepIndicatorUntilLastFinishes` | Multiple in-flight expands; indicator off only when all complete |
| `testReopeningThreadReusesCacheWithoutForcingReindex` | Switch thread → merge persists; re-switch → no new indexing, old merge still there |
| `testRefreshReloadsExpandedPrunedSubtreesToSurfaceNewFiles` | FS change triggers full reindex; auto-re-loads previously expanded subtrees |
| `testAppModelPublishesFullBrowseIndexAndSearchesAcrossFullIndex` | 150k entries, full index searchable, fuzzy works, adjacent-file nav works |
| `testClearingLargeIndexSearchRestoresFullBrowseList` | Search limit applied; clearing query restores full list |
| `testAppModelPublishesFilesWhenLargeCachedIndexStartsWithDirectories` | 12k dirs + 4k files: both shown; visible includes files |

### Benchmark Targets (FuzzyMatcherBenchmarks, FileIndexerBenchmarks, TreeBuilderBenchmarks)

| Benchmark | Target | Threshold |
|-----------|--------|-----------|
| `test_bench_fuzzy_50k_threeChar` | 50k entries, 3-char query, no limit | ≤ 400 ms (debounced) |
| `test_bench_fuzzy_50k_cappedThreeChar` | 50k entries, 3-char query, limit 1000 | ≤ 400 ms (bounded heap) |
| `test_bench_fuzzy_150k_cappedThreeChar` | 150k entries, 3-char query, limit 1000 | ≤ 400 ms (bounded heap) |
| `test_bench_index_largeRepo` | 50k files, 2k dirs, ignored dirs | ≤ 1.5 s cold index |
| `test_bench_childrenIndex_150k` | Build children map from 150k entries | ≤ acceptable (one-time per index) |
| `test_bench_visibleRows_index_150k_oneExpandedBranch` | Walk index with one branch expanded, 10k limit | proportional to rows, not total |
| `test_bench_visibleRows_150k_cappedTenThousandRows` | All folders expanded, 10k cap | ≤ acceptable |
| `test_bench_treeBuilder_50k` | Build tree structure from 50k entries | ≤ 61 ms |

---

## Persistence & Storage

### Cache Storage (via `YAAWStore.upsertCachedFileIndex()`)

- `CachedFileIndex` = metadata + entries array
- Keyed by `metadata.cacheKey` (the computed hash string)
- Persisted to SQLite (Chunk A responsibility)
- Invalidated when: root/branch/rules/schema change (key differs)

### Session State (NOT persisted across relaunch)

- `expandedFoldersByThreadID: [UUID: Set<String>]` — per-thread, lost on relaunch (per spec: "now persisted" in Chunk E LayoutStore)
- `selectedFileByThreadID: [UUID: String]` — per-thread, lost on relaunch (per spec: "now persisted" in Chunk E RightPanelStore)
- `nvimRelativePathsByThreadID: [UUID: String]` — per-thread nvim path, lost on relaunch (ditto)

**New in rewrite (Chunk E):** these move into observable stores so they survive relaunch.

---

## Error Handling

### Loud Failures

- `FileBrowserIndexError.missingRoot(String)` — thrown if root directory doesn't exist
- Propagated via completion handler as `.failure(error)`
- Surfaced to `ActivityStore` as visible thread state (not silent)

### Silent Swallows (preserve behavior)

- `.git` read errors → fallback to `.notRepository`
- File metadata reads on enumeration → skip entry (already filtered by enumerator)
- Ignore rule parsing edge cases → normalized empty strings filtered out

---

## Exact File References for Implementation

| Topic | File | Line Range |
|-------|------|-----------|
| Git identity resolution | `FileIndexCache.swift` | 27–43, 45–80 |
| Cache key formula | `FileIndexCache.swift` | 90–123 |
| Fingerprint hash | `FileIndexCache.swift` | 115–122 |
| Directory watcher | `FileIndexDirectoryWatcher.swift` | 1–85 |
| FSEvents debounce | `FileIndexDirectoryWatcher.swift` | 74 |
| Full index build | `FileBrowserIndex.swift` | 156–221 |
| Subtree build | `FileBrowserIndex.swift` | 110–142 |
| Ignore matcher | `FileBrowserIndex.swift` | 224–245 |
| Path normalizer | `FileBrowserIndex.swift` | 247–268 |
| Merge algorithm (to refactor) | `FileBrowserTreeBuilder.swift` | 205–218 |
| Sort algorithm | `FileBrowserTreeBuilder.swift` | 220–253 |
| Visible rows walk | `FileBrowserTreeBuilder.swift` | 106–137, 139–167 |
| Children index | `FileBrowserTreeBuilder.swift` | 84–98 |
| Fuzzy rank | `FileBrowserIndex.swift` | 354–389 |
| Bounded heap | `FileBrowserIndex.swift` | 397–457 |
| Cache coordinator dedup | `FileIndexCache.swift` | 167–218, 259–287 |

---

## Master Plan Alignment

From **00-master-plan.md §Chunk B**:

> - **Scope:** Move walk/cache/fuzzy/watch behind a `FileIndexActor`. **Keep** the durable shared cache (keyed by root + git identity + ignore fingerprint + schema), dedup, lazy pruned-subtree expansion, capped visible rows, 350 ms FSEvents debounce. **Fix:** replace the full re-sort on subtree merge with sorted insertion/merge; **session-cache** the `.git/HEAD` read (was per index call). Expose incremental re-rank via `AsyncStream`.
> - **Acceptance + perf gate:** fuzzy 50k/3-char perceived ≤ **400 ms** (debounced; 916 ms uncapped baseline); cold index 50k ≤ **1.5 s** (no regression); tree builder 50k ≤ **61 ms** (no regression); UI stays responsive during indexing.

**This spec satisfies:**
- ✅ All keep/fix items spelled out
- ✅ Perf thresholds articulated
- ✅ Test parity list complete
- ✅ Concurrency model (actor, no NSLock, @Sendable boundaries)
- ✅ Exact algorithms + constants + file refs

