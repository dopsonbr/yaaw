import Foundation

/// The YAAW end-to-end driver/runner. Two roles in one binary:
///
/// 1. **Headless durable-state runner** (`--artifacts <dir>`): builds fixtures +
///    command doubles, drives the five stores through the full no-mock journey,
///    asserts durable-state transitions, and writes the visual-state SQLite
///    databases the launched app screenshots. This runs without a GUI and is the
///    portion verified in Chunk G.
/// 2. **Headless driver subcommands** (`screenshot`/`send-key`/`send-click`/
///    `kill-helper`/`frontmost`): PID-targeted CGEvents + ScreenCaptureKit
///    composites + the crash-isolation kill, used by `scripts/test-e2e.sh`
///    against the launched signed app (GUI/accessibility-bound).
@main
struct YAAWE2E {
    static func main() async {
        do {
            if try await E2EDriverCommands.run(arguments: CommandLine.arguments) {
                return
            }
            let options = try E2EOptions(arguments: CommandLine.arguments)
            try await E2ERunner(artifactsDirectory: options.artifactsDirectory).run()
        } catch {
            FileHandle.standardError.write(Data("YAAWE2E: \(error)\n".utf8))
            exit(1)
        }
    }
}
