import Foundation

/// Build provenance stamped into the bundle by script/build_and_run.sh.
/// `swift run` has no bundle Info.plist, so the commit reads as a dev run.
enum AppBuildInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0"

    static let commit: String =
        Bundle.main.object(forInfoDictionaryKey: "YAAWBuildCommit") as? String
        ?? "unstamped (swift run)"

    /// One-line summary for the Settings build row, e.g. "0.0.1 · 1d4caac8f0".
    static var summary: String {
        "\(version) · \(commit)"
    }
}
