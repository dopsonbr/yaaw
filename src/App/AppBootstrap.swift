import AppKit
import Foundation
import Observation
import SwiftUI
import YAAWKit

/// The fully wired app context: the stores, the render client, and the
/// settings-window model, plus the AppKit-only `ExternalOpenWorkspace`.
@MainActor
struct AppContext {
    let stores: AppStores
    let renderHostClient: RenderHostClient
    let externalOpenWorkspace: ExternalOpenWorkspace
}

/// Builds the real `AppEnvironment` (SQLite store, actors, render client,
/// notification/badge dispatchers) and the `AppStores` set. `AppStores.make` is
/// async (it loads the snapshot once), so the SwiftUI scene shows a loading view
/// until `load()` completes. The persistence open failure is surfaced (never an
/// in-memory fallback that could hide real data).
@MainActor
@Observable
final class AppBootstrap {
    private(set) var context: AppContext?
    private(set) var settingsModel: SettingsModel?
    private(set) var startupError: Error?
    let databasePath: URL

    private let configurationStore: YAMLConfigurationStore
    private let configurationPath: URL
    private let environment: [String: String]
    private let envPrefix: String
    private var hasLoaded = false

    init() {
        let environment = ProcessInfo.processInfo.environment
        self.environment = environment
        self.envPrefix =
            Bundle.main.bundleIdentifier == "dev.dopsonbr.YAAW.E2E" ? "YAAW_E2E_" : "YAAW_"
        var applied: [String] = []
        self.databasePath = Self.databasePath(
            environment: environment, envPrefix: envPrefix, applied: &applied)
        self.configurationPath = Self.configurationPath(
            environment: environment, envPrefix: envPrefix, applied: &applied)
        self.configurationStore = YAMLConfigurationStore(
            path: configurationPath, diagnosticRecorder: LoggerDiagnosticEventRecorder.shared)
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        let diagnostics = LoggerDiagnosticEventRecorder.shared
        let store: any YAAWStore
        do {
            store = try SQLiteYAAWStore(
                databasePath: databasePath, diagnosticRecorder: diagnostics)
        } catch {
            startupError = error
            diagnostics.record(
                DiagnosticEvent(
                    category: "Lifecycle", name: "app_startup_failed",
                    metadata: ["error": String(describing: error)]))
            return
        }

        let isHeadlessE2E = environment["YAAW_E2E_HEADLESS"] == "1"
        let externalToolResolver = PATHAgentCLIExecutableResolver()
        let sessionBindingActor = SessionBindingActor(
            resolver: externalToolResolver, environment: environment)
        let fileIndexActor = FileIndexActor(store: store)
        let renderHostClient = RenderHostClient(diagnosticRecorder: diagnostics)

        let appEnvironment = AppEnvironment(
            persistenceStore: store,
            fileIndexActor: fileIndexActor,
            sessionBindingActor: sessionBindingActor,
            renderSurfaceManager: renderHostClient,
            externalToolResolver: externalToolResolver,
            notificationDispatcher: isHeadlessE2E
                ? NoopThreadActivityNotificationDispatcher()
                : MacSystemThreadActivityNotificationDispatcher.shared,
            badgeUpdater: MacDockThreadActivityBadgeUpdater.shared,
            diagnosticRecorder: diagnostics,
            isApplicationActive: { NSApplication.shared.isActive },
            environment: environment
        )

        let stores = await AppStores.make(environment: appEnvironment)
        // Seed the configuration from disk so the stores' SettingsStore reflects
        // the persisted YAML (the store starts from defaults).
        stores.settings.reloadConfiguration(configurationStore.load())

        let context = AppContext(
            stores: stores,
            renderHostClient: renderHostClient,
            externalOpenWorkspace: ExternalOpenWorkspace()
        )
        self.context = context
        self.settingsModel = makeSettingsModel(settings: stores.settings)
    }

    private func makeSettingsModel(settings: SettingsStore) -> SettingsModel {
        let configurationStore = configurationStore
        let configurationPath = configurationPath
        return SettingsModel(
            dependencies: SettingsModel.Dependencies(
                settingsPath: configurationPath,
                loadText: { try configurationStore.loadText() },
                validateText: { try configurationStore.validate(text: $0) },
                saveText: { text in
                    try configurationStore.saveText(text)
                    let configuration = try configurationStore.validate(text: text)
                    settings.reloadConfiguration(configuration)
                    return configuration
                },
                openExternal: {
                    try? configurationStore.ensureFileExists()
                    NSWorkspace.shared.open(configurationPath)
                },
                reloadConfiguration: {
                    settings.reloadConfiguration(configurationStore.load())
                },
                refreshAgentCLIOptions: {
                    settings.refreshAgentCLIOptionCatalog()
                }
            )
        )
    }

    // MARK: - Env overrides

    private static func databasePath(
        environment: [String: String], envPrefix: String, applied: inout [String]
    ) -> URL {
        let key = "\(envPrefix)DATABASE_PATH"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value)
        }
        return SQLiteYAAWStore.defaultDatabasePath()
    }

    private static func configurationPath(
        environment: [String: String], envPrefix: String, applied: inout [String]
    ) -> URL {
        let key = "\(envPrefix)CONFIG_PATH"
        if let value = environment[key] {
            applied.append(key)
            return URL(fileURLWithPath: value)
        }
        return YAMLConfigurationStore.defaultPath()
    }
}
