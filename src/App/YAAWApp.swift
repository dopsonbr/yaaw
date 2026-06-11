import AppKit
import Darwin
import SwiftUI
import YAAWKit

@main
struct YAAWApp: App {
    static let settingsWindowID = "yaaw-settings"

    @NSApplicationDelegateAdaptor(YAAWApplicationDelegate.self) private var appDelegate
    @State private var bootstrap: AppBootstrap

    /// Two live instances of the same bundle identifier corrupt each other's
    /// helper compositing, so the newest launch wins. Lives in App.init, not the
    /// app delegate: LaunchServices launches do not deliver the delegate's
    /// launching callbacks. SIGTERM rather than NSRunningApplication.terminate()
    /// because the app ignores the quit Apple event while unfocused.
    private static let duplicateInstanceSweep: Void = {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let myLaunch = NSRunningApplication.current.launchDate ?? Date()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPid }
            .filter { ($0.launchDate ?? .distantPast) <= myLaunch }
        guard !others.isEmpty else { return }
        for app in others {
            Darwin.kill(app.processIdentifier, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in others where !app.isTerminated {
                app.forceTerminate()
            }
        }
    }()

    init() {
        _ = Self.duplicateInstanceSweep
        BundledFontCatalog.registerBundledFonts(
            diagnosticRecorder: LoggerDiagnosticEventRecorder.shared)
        _bootstrap = State(initialValue: AppBootstrap())
    }

    var body: some Scene {
        WindowGroup("Agent IDE") {
            RootContainerView(
                bootstrap: bootstrap,
                appDelegate: appDelegate,
                onInstallLatestRelease: installLatestRelease
            )
            .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1400, height: 900)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About YAAW") {
                    NSApp.orderFrontStandardAboutPanel(options: [.version: AppBuildInfo.commit])
                }
            }
            if let context = bootstrap.context {
                AppCommandMenus(
                    stores: context.stores,
                    externalOpenWorkspace: context.externalOpenWorkspace,
                    settingsWindowID: Self.settingsWindowID
                )
            }
        }

        Window("Settings", id: Self.settingsWindowID) {
            if let context = bootstrap.context, let settingsModel = bootstrap.settingsModel {
                SettingsWindowView(model: settingsModel, settings: context.stores.settings)
                    .preferredColorScheme(
                        context.stores.settings.resolvedTheme.swiftUIColorScheme)
            }
        }
        .defaultSize(width: 980, height: 680)
        .restorationBehavior(.disabled)
    }

    private func installLatestRelease() {
        do {
            try AppUpdateInstaller.shared.installLatestRelease()
            NSApplication.shared.terminate(nil)
        } catch {
            LoggerDiagnosticEventRecorder.shared.record(
                DiagnosticEvent(
                    category: "Lifecycle",
                    name: "update_install_failed",
                    metadata: ["error": String(describing: error)]
                )
            )
        }
    }
}

/// Root window content. Holds the `openWindow` environment action so the chrome
/// and forwarded shortcuts can open the standalone Settings window scene, and
/// drives the async store bootstrap.
private struct RootContainerView: View {
    @Bindable var bootstrap: AppBootstrap
    let appDelegate: YAAWApplicationDelegate
    let onInstallLatestRelease: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let startupError = bootstrap.startupError {
                PersistenceStartupFailureView(
                    error: startupError, databasePath: bootstrap.databasePath)
            } else if let context = bootstrap.context {
                RootView(
                    stores: context.stores,
                    renderHostClient: context.renderHostClient,
                    externalOpenWorkspace: context.externalOpenWorkspace,
                    onInstallLatestRelease: onInstallLatestRelease,
                    onOpenSettings: { openWindow(id: YAAWApp.settingsWindowID) }
                )
                .preferredColorScheme(context.stores.settings.resolvedTheme.swiftUIColorScheme)
                .onAppear {
                    appDelegate.installSystemAppearanceObserver(for: context.stores.settings)
                }
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(dracula(.background))
            }
        }
        .task { await bootstrap.load() }
    }
}

@MainActor
private final class YAAWApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let systemAppearanceObserver = SystemAppearanceObserver()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == "dev.dopsonbr.YAAW.E2E",
            ProcessInfo.processInfo.environment["YAAW_E2E_HEADLESS"] == "1"
        {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            _ = Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Darwin.exit(0) }
                }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func installSystemAppearanceObserver(for settings: SettingsStore) {
        systemAppearanceObserver.install { isDark in
            settings.updateSystemAppearance(isDark: isDark)
        }
    }
}

private struct PersistenceStartupFailureView: View {
    let error: Error
    let databasePath: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Persistence needs attention")
                .font(.title2.weight(.semibold))
                .foregroundStyle(dracula(.red))

            Text(
                "The app did not open an in-memory fallback because doing so could hide existing projects or threads."
            )
            .foregroundStyle(dracula(.foreground))
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Database")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))
                Text(databasePath.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(dracula(.cyan))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Error")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dracula(.comment))
                Text(String(describing: error))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(dracula(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dracula(.background))
    }
}
