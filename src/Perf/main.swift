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

@main
struct PerfMain {
    static func main() async {
        do {
            let gates = try await runPersistenceGates()
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
