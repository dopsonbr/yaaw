import AppKit
import Foundation

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
