import Foundation
import YAAWKit

// Release-buildable performance harness. XCTest benchmark targets cannot be
// compiled with `-c release` on the current toolchain (a frontend "circular
// reference" crash whenever an XCTest target imports YAAWKit — DECISIONS-LOG
// D-010), so the authoritative release perf gate runs here instead, via
// `swift run -c release YAAWKitPerf`. Each chunk's release-sensitive perf
// targets are asserted here. Public API only — no @testable.

struct PerfFailure: Error { let message: String }

@MainActor
func median(iterations: Int, _ body: () async -> Void) async -> Double {
    let clock = ContinuousClock()
    var samples: [Duration] = []
    for _ in 0..<iterations {
        let start = clock.now
        await body()
        samples.append(clock.now - start)
    }
    samples.sort()
    let sample = samples[samples.count / 2]
    return Double(sample.components.seconds) * 1_000
        + Double(sample.components.attoseconds) / 1e15
}

func makeSnapshot(threadCount: Int) -> YAAWSnapshot {
    let projectID = UUID()
    let project = Project(
        id: projectID,
        displayName: "PerfProject",
        rootDirectory: URL(fileURLWithPath: "/tmp/perf", isDirectory: true)
    )
    let threads = (0..<threadCount).map { index in
        AgentThread(
            id: UUID(),
            displayName: "thread-\(index)",
            projectID: projectID,
            workingDirectory: URL(fileURLWithPath: "/tmp/perf/\(index)", isDirectory: true),
            agentCLI: .codex,
            createdAt: Date(timeIntervalSince1970: Double(index)),
            lastOpenedAt: Date(timeIntervalSince1970: Double(index)),
            isArchived: index % 7 == 0
        )
    }
    return YAAWSnapshot(
        projects: [project],
        threads: threads,
        selectedProjectID: projectID,
        selectedThreadID: threads.first?.id,
        rightPanelModesByThreadID: [:],
        selectedRightPanelMode: .files,
        isGlobalTerminalExpanded: false
    )
}

func tempStore() throws -> SQLiteYAAWStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWPerf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try SQLiteYAAWStore(databasePath: dir.appendingPathComponent("state.sqlite"))
}

struct Gate {
    let label: String
    let value: Double
    let target: Double
    var passed: Bool { value <= target }
}

@MainActor
func runPersistenceGates() async throws -> [Gate] {
    var gates: [Gate] = []

    let saveStore = try tempStore()
    let snapshot10k = makeSnapshot(threadCount: 10_000)
    let saveMs = await median(iterations: 10) { await saveStore.save(snapshot10k) }
    gates.append(Gate(label: "save @10k", value: saveMs, target: 30))

    let loadStore = try tempStore()
    await loadStore.save(snapshot10k)
    let loadMs = await median(iterations: 10) { _ = await loadStore.load() }
    gates.append(Gate(label: "load @10k", value: loadMs, target: 10))

    let editStore = try tempStore()
    await editStore.save(snapshot10k)
    var edit = await editStore.load()
    let editMs = await median(iterations: 50) {
        edit.threads[0].displayName = "edited"
        let thread = edit.threads[0]
        await editStore.upsertThread(thread)
    }
    gates.append(Gate(label: "single edit @10k", value: editMs, target: 2))

    return gates
}

/// WorkspaceStore gates (Chunk E): the O(1) keyed lookup for the selected
/// project's active threads must read ≤ 0.1 ms @ 10k threads, and `selectThread`
/// (which patches the caches, not a full re-sort) must stay fast.
@MainActor
func runWorkspaceGates() async throws -> [Gate] {
    var gates: [Gate] = []

    let store = InMemoryYAAWStore(snapshot: makeSnapshot(threadCount: 10_000))
    let environment = AppEnvironment(
        persistenceStore: store,
        fileIndexActor: FileIndexActor(store: store)
    )
    let stores = await AppStores.make(environment: environment)
    let workspace = stores.workspace

    let readMs = medianSync(iterations: 1_000) {
        _ = workspace.activeThreadsForSelectedProject
    }
    gates.append(Gate(label: "activeThreads @10k", value: readMs, target: 0.1))

    let candidates = workspace.activeThreadsForSelectedProject
    guard candidates.count >= 2 else { throw PerfFailure(message: "expected active threads @10k") }
    let threadIDs = candidates.prefix(200).map(\.id)
    var cursor = 0
    let selectMs = medianSync(iterations: 200) {
        workspace.selectThread(id: threadIDs[cursor % threadIDs.count])
        cursor += 1
    }
    // selectThread patches the per-project sorted cache in place (sorted
    // insertion after an O(n) locate). The 10k fixture is a single project, so
    // this is the worst case; the spec's hard gate is the O(1) read above.
    gates.append(Gate(label: "selectThread @10k", value: selectMs, target: 20.0))
    await workspace.flushPersistence()

    return gates
}

/// Median wall-clock milliseconds of a synchronous `body` across `iterations`.
func medianSync(iterations: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    var samples: [Duration] = []
    for _ in 0..<iterations {
        let start = clock.now
        body()
        samples.append(clock.now - start)
    }
    samples.sort()
    let sample = samples[samples.count / 2]
    return Double(sample.components.seconds) * 1_000
        + Double(sample.components.attoseconds) / 1e15
}

func synthesizeFileIndexEntries(count: Int) -> [FileBrowserEntry] {
    let suffixes = ["swift", "ts", "go", "py", "md", "json", "yaml", "rs", "c", "h"]
    let topDirs = ["src", "tests", "docs", "scripts", "vendor", "scenarios", "internal", "pkg"]
    let midDirs = ["core", "view", "model", "render", "store", "util", "feature", "api"]
    var entries: [FileBrowserEntry] = []
    entries.reserveCapacity(count + topDirs.count + topDirs.count * midDirs.count)
    for top in topDirs {
        entries.append(FileBrowserEntry(relativePath: top, isDirectory: true))
        for mid in midDirs {
            entries.append(FileBrowserEntry(relativePath: "\(top)/\(mid)", isDirectory: true))
        }
    }
    for index in 0..<count {
        let top = topDirs[index % topDirs.count]
        let mid = midDirs[(index / topDirs.count) % midDirs.count]
        let leaf = "module_\(index)_scenario.\(suffixes[index % suffixes.count])"
        entries.append(
            FileBrowserEntry(relativePath: "\(top)/\(mid)/\(leaf)", isDirectory: false))
    }
    return entries
}

func makeFileIndexFixture(files: Int, directories: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("YAAWPerfIndex-\(UUID().uuidString)", isDirectory: true)
    let fileManager = FileManager.default
    let directoryURLs: [URL] = try (0..<directories).map { idx in
        let dir = root.appendingPathComponent("dir_\(idx)/sub_\(idx % 50)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    for index in 0..<files {
        let dir = directoryURLs[index % max(directoryURLs.count, 1)]
        try Data().write(to: dir.appendingPathComponent("file_\(index).txt"))
    }
    let nodeModules = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
    try fileManager.createDirectory(at: nodeModules, withIntermediateDirectories: true)
    for index in 0..<1_000 {
        try Data().write(to: nodeModules.appendingPathComponent("m_\(index).js"))
    }
    return root
}

/// Release-sensitive file-index perf gates (Chunk B). Pure-algorithm gates use a
/// synchronous median; the cold-index gate enumerates a real 50k-file fixture.
func runFileIndexGates() throws -> [Gate] {
    var gates: [Gate] = []

    let entries50k = synthesizeFileIndexEntries(count: 50_000)
    let fuzzyCappedMs = medianSync(iterations: 10) {
        _ = FuzzyFileMatcher.rankedResult(entries50k, query: "swi", limit: 1_000)
    }
    gates.append(Gate(label: "fuzzy 50k 3-char cap", value: fuzzyCappedMs, target: 400))

    let treeMs = medianSync(iterations: 10) {
        _ = FileBrowserTreeBuilder.roots(from: entries50k)
    }
    gates.append(Gate(label: "tree builder 50k", value: treeMs, target: 61))

    let fixtureRoot = try makeFileIndexFixture(files: 50_000, directories: 2_000)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let coldIndexMs = medianSync(iterations: 3) {
        _ = try? BackgroundFileIndexer.buildIndex(
            threadID: UUID(), root: fixtureRoot,
            ignoreRules: YAAWConfiguration.defaultIgnoreRules)
    }
    gates.append(Gate(label: "cold index 50k", value: coldIndexMs, target: 1_500))

    return gates
}

@main
struct PerfMain {
    static func main() async {
        do {
            var gates = try await runPersistenceGates()
            gates.append(contentsOf: try runFileIndexGates())
            gates.append(contentsOf: try await runWorkspaceGates())
            var failures: [String] = []
            print("=== YAAW perf gates (\(perfConfigurationName)) ===")
            for gate in gates {
                let status = gate.passed ? "PASS" : "FAIL"
                print(
                    String(
                        format: "  [%@] %-20@ %.3f ms (target ≤ %.0f ms)",
                        status, gate.label as NSString, gate.value, gate.target))
                if !gate.passed { failures.append(gate.label) }
            }
            if failures.isEmpty {
                print("All perf gates met.")
            } else {
                print("FAILED gates: \(failures.joined(separator: ", "))")
                exit(1)
            }
        } catch {
            print("perf harness error: \(error)")
            exit(2)
        }
    }
}

private var perfConfigurationName: String {
    #if DEBUG
        "debug — informational only; release is the gate"
    #else
        "release"
    #endif
}
