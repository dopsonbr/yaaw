import CoreText
import Foundation
import Synchronization

/// Registers fonts vendored in the YAAWKit resource bundle for the current process.
///
/// Both the main app and the YAAWRenderHost helper must call this at startup: Ghostty
/// discovers fonts through CoreText inside the helper process, and process-scope
/// registrations do not cross process boundaries.
public enum BundledFontCatalog {
    /// PostScript family name of the vendored JetBrains Mono font.
    public static let jetBrainsMonoFamily = "JetBrains Mono"

    private static let resourceBundleName = "YAAW_YAAWKit.bundle"
    private static let fontDirectoryName = "JetBrainsMono"

    /// One-time-registration guard. `Mutex` is `Sendable` without an
    /// `@unchecked`/`nonisolated(unsafe)` escape hatch (rewrite tightened
    /// standards: zero `@unchecked Sendable`).
    private static let registrationGuard = Mutex(false)

    /// Registers every bundled font with process scope. Safe to call more than once;
    /// repeat calls and fonts the user already installed are treated as success.
    @discardableResult
    public static func registerBundledFonts(
        diagnosticRecorder: DiagnosticEventRecording? = nil
    ) -> Bool {
        registrationGuard.withLock { didRegister in
            if didRegister { return true }
            let success = performRegistration(diagnosticRecorder: diagnosticRecorder)
            if success { didRegister = true }
            return success
        }
    }

    private static func performRegistration(
        diagnosticRecorder: DiagnosticEventRecording?
    ) -> Bool {
        guard let fontDirectory = locateFontDirectory() else {
            diagnosticRecorder?.record(
                DiagnosticEvent(
                    category: "Fonts",
                    name: "bundled_fonts_missing",
                    metadata: ["directory": fontDirectoryName]
                )
            )
            return false
        }

        let directoryContents =
            (try? FileManager.default.contentsOfDirectory(
                at: fontDirectory, includingPropertiesForKeys: nil)) ?? []
        let fontURLs =
            directoryContents
            .filter { $0.pathExtension.lowercased() == "ttf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !fontURLs.isEmpty else {
            diagnosticRecorder?.record(
                DiagnosticEvent(
                    category: "Fonts",
                    name: "bundled_fonts_missing",
                    metadata: ["directory": fontDirectory.path]
                )
            )
            return false
        }

        var failures: [String: String] = [:]
        for fontURL in fontURLs {
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
            if !registered, let error = error?.takeRetainedValue(),
                !isTolerableRegistrationError(error)
            {
                failures[fontURL.lastPathComponent] = String(describing: error)
            }
        }

        if failures.isEmpty {
            diagnosticRecorder?.record(
                DiagnosticEvent(
                    category: "Fonts",
                    name: "bundled_fonts_registered",
                    metadata: [
                        "count": String(fontURLs.count),
                        "directory": fontDirectory.path,
                    ]
                )
            )
            return true
        }

        diagnosticRecorder?.record(
            DiagnosticEvent(
                category: "Fonts",
                name: "bundled_font_registration_failed",
                metadata: failures
            )
        )
        return false
    }

    /// Resolves the vendored font directory across every runtime shape: the packaged
    /// .app (Contents/Resources), `swift run`/`swift test` (bundle beside the binary),
    /// and the helper inside the .app (Contents/Helpers next to Contents/Resources).
    private static func locateFontDirectory() -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory)
            candidates.append(
                executableDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true))
        }
        for bundle in Bundle.allBundles {
            candidates.append(bundle.bundleURL.deletingLastPathComponent())
        }

        for candidate in candidates {
            let fontDirectory =
                candidate
                .appendingPathComponent(resourceBundleName, isDirectory: true)
                .appendingPathComponent(fontDirectoryName, isDirectory: true)
            if FileManager.default.fileExists(atPath: fontDirectory.path) {
                return fontDirectory
            }
        }
        return nil
    }

    private static func isTolerableRegistrationError(_ error: CFError) -> Bool {
        guard CFErrorGetDomain(error) as String? == kCTFontManagerErrorDomain as String else {
            return false
        }
        let code = CFErrorGetCode(error)
        return code == CTFontManagerError.alreadyRegistered.rawValue
            || code == CTFontManagerError.duplicatedName.rawValue
    }
}
