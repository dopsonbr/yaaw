import AppKit
import XCTest

@testable import YAAWKit

final class KeyboardShortcutEventMatchingTests: XCTestCase {
    func testCommandShortcutMatchesDefaultAction() throws {
        let event = try shortcutEvent(characters: "j", modifiers: [.command])

        XCTAssertTrue(KeyboardShortcutAction.toggleBottomTerminal.defaultShortcut.matches(event))
        XCTAssertFalse(KeyboardShortcutAction.openSettings.defaultShortcut.matches(event))
    }

    func testShiftedPunctuationMatchesCharactersIgnoringModifiers() throws {
        let previous = try shortcutEvent(
            characters: "{",
            charactersIgnoringModifiers: "[",
            modifiers: [.command, .shift]
        )
        let next = try shortcutEvent(
            characters: "}",
            charactersIgnoringModifiers: "]",
            modifiers: [.command, .shift]
        )
        let nextFromShiftedCharacter = try shortcutEvent(
            characters: "}",
            charactersIgnoringModifiers: "}",
            modifiers: [.command, .shift]
        )

        XCTAssertTrue(
            KeyboardShortcutAction.previousRightPanelMode.defaultShortcut.matches(previous))
        XCTAssertTrue(KeyboardShortcutAction.nextRightPanelMode.defaultShortcut.matches(next))
        XCTAssertTrue(
            KeyboardShortcutAction.nextRightPanelMode.defaultShortcut.matches(
                nextFromShiftedCharacter))
    }

    func testCommandVDoesNotMatchAnyDefaultYAAWShortcut() throws {
        let event = try shortcutEvent(characters: "v", modifiers: [.command])

        XCTAssertFalse(
            KeyboardShortcutAction.allCases.contains { action in
                action.defaultShortcut.matches(event)
            }
        )
    }

    func testAppModelDisablesUnboundAndDuplicateShortcuts() {
        var shortcuts = KeyboardShortcutSettings()
        shortcuts.setDefinition(.unbound, for: .toggleBottomTerminal)
        shortcuts.setDefinition(
            KeyboardShortcutDefinition(key: "r", modifiers: [.command]),
            for: .reloadSettings
        )
        let configuration = YAAWConfiguration(keyboardShortcuts: shortcuts)
        let model = AppModel(store: InMemoryYAAWStore.helloWorld(), configuration: configuration)

        XCTAssertFalse(model.isKeyboardShortcutEnabled(for: .toggleBottomTerminal))
        XCTAssertFalse(model.isKeyboardShortcutEnabled(for: .refreshFiles))
        XCTAssertFalse(model.isKeyboardShortcutEnabled(for: .reloadSettings))
    }

    private func shortcutEvent(
        characters: String,
        charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
                isARepeat: false,
                keyCode: 0
            ))
    }
}
