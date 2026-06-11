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

    // NOTE: testAppModelDisablesUnboundAndDuplicateShortcuts depends on AppModel +
    // InMemoryYAAWStore (the unbound/duplicate-shortcut disabling behavior). It is
    // re-homed onto SettingsStore in Chunk E (Stores), where that behavior now
    // lives, and verified there. The pure event-matching behavior stays here.

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
