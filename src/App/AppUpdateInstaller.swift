import AppKit
import Foundation

/// Runs the public release installer in Terminal so a new build can replace the
/// running app after it quits.
@MainActor
final class AppUpdateInstaller {
    static let shared = AppUpdateInstaller()

    private let installCommand: String

    init(
        installCommand: String =
            "curl -fsSL https://raw.githubusercontent.com/dopsonbr/yaaw/main/scripts/install-release.sh | /bin/sh"
    ) {
        self.installCommand = installCommand
    }

    func installLatestRelease() throws {
        let escapedCommand =
            installCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
            tell application "Terminal"
              activate
              do script "\(escapedCommand)"
            end tell
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        try process.run()
    }
}
