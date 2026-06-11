import XCTest

@testable import YAAWKit

final class KeyboardShortcutConfigurationTests: PersistenceTestCase {
    func testYAMLConfigurationRendersEveryKeyboardShortcutAction() throws {
        let rendered = YAMLConfigurationStore.render(YAAWConfiguration())

        for action in KeyboardShortcutAction.allCases {
            XCTAssertTrue(rendered.contains("\(action.rawValue):"), "Missing \(action.rawValue)")
        }
    }

    func testYAMLConfigurationAllowsUnboundKeyboardShortcuts() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  archiveSelectedThread:
                    key: ""
                    modifiers: []
                """
        )

        XCTAssertTrue(configuration.shortcut(for: .archiveSelectedThread).isUnbound)
    }

    func testYAMLConfigurationFallsBackInvalidKeyboardShortcutToDefault() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  toggleBottomTerminal:
                    key: too-long
                    modifiers: []
                """
        )

        XCTAssertEqual(
            configuration.shortcut(for: .toggleBottomTerminal),
            KeyboardShortcutAction.toggleBottomTerminal.defaultShortcut)
    }

    func testYAMLConfigurationDetectsDuplicateKeyboardShortcutsWithinScope() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  selectFilesRightPanelMode:
                    key: "7"
                    modifiers: [command]
                  selectGitRightPanelMode:
                    key: "7"
                    modifiers: [command]
                """
        )

        XCTAssertEqual(
            configuration.keyboardShortcuts.duplicateActions(),
            [.selectFilesRightPanelMode, .selectGitRightPanelMode]
        )
    }

    func testDefaultKeyboardShortcutsDoNotConflict() {
        XCTAssertTrue(YAAWConfiguration().keyboardShortcuts.duplicateActions().isEmpty)
    }

    func testYAMLConfigurationDetectsDuplicateKeyboardShortcutsAcrossCommandScopes() throws {
        let store = YAMLConfigurationStore(
            path: try temporaryDirectory().appendingPathComponent("settings.yaml"))

        let configuration = try store.validate(
            text: """
                keyboardShortcuts:
                  reloadSettings:
                    key: "r"
                    modifiers: [command]
                """
        )

        XCTAssertEqual(
            configuration.keyboardShortcuts.duplicateActions(),
            [.refreshFiles, .reloadSettings]
        )
    }
}
