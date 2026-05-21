import AppKit
import XCTest
@testable import YAAWKit

final class TerminalPasteTests: XCTestCase {
    func testImagePastePolicyUsesNativeAttachmentShortcutForEveryCLI() {
        let policy = TerminalImagePastePolicy()

        for kind in AgentCLIKind.allCases {
            XCTAssertEqual(
                policy.textForImagePaste(agentCLI: kind),
                TerminalImagePastePolicy.nativeAttachmentShortcutText
            )
        }
    }

    func testImagePastePolicyDoesNotExposeFilesystemPathForAnyCLI() {
        let policy = TerminalImagePastePolicy()

        for kind in AgentCLIKind.allCases {
            let text = policy.textForImagePaste(agentCLI: kind)
            XCTAssertFalse(text.contains("Attached image:"))
            XCTAssertFalse(text.contains("/tmp/"))
            XCTAssertFalse(text.contains("/Users/"))
        }
    }

    func testPasteShortcutDoesNotMatchReturnKey() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 0x24
        ))

        XCTAssertFalse(TerminalPasteShortcut.matches(event))
    }

    func testPasteShortcutMatchesCommandVAndControlVOnly() throws {
        let commandV = try shortcutEvent(characters: "v", modifiers: [.command])
        let controlV = try shortcutEvent(characters: "v", modifiers: [.control])
        let shiftedCommandV = try shortcutEvent(characters: "v", modifiers: [.command, .shift])

        XCTAssertTrue(TerminalPasteShortcut.matches(commandV))
        XCTAssertTrue(TerminalPasteShortcut.matches(controlV))
        XCTAssertFalse(TerminalPasteShortcut.matches(shiftedCommandV))
    }

    func testPasteboardExtractorReadsPNGData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("YAAWKitTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Self.samplePNGData(), forType: .png)

        XCTAssertNotNil(PasteboardImageExtractor.pngData(from: pasteboard))
    }

    func testPasteboardExtractorReadsImageFileURL() throws {
        let directory = try temporaryDirectory()
        let imageURL = directory.appendingPathComponent("image.png")
        try Self.samplePNGData().write(to: imageURL)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("YAAWKitTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([imageURL as NSURL])

        XCTAssertNotNil(PasteboardImageExtractor.pngData(from: pasteboard))
    }

    func testPasteboardExtractorReadsRTFDAttachment() throws {
        let fileWrapper = FileWrapper(regularFileWithContents: Self.samplePNGData())
        fileWrapper.preferredFilename = "image.png"
        let directoryWrapper = FileWrapper(directoryWithFileWrappers: ["image.png": fileWrapper])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("YAAWKitTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(directoryWrapper.serializedRepresentation, forType: .rtfd)

        XCTAssertNotNil(PasteboardImageExtractor.pngData(from: pasteboard))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAAWKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shortcutEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0x09
        ))
    }

    private static func samplePNGData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return PasteboardImageExtractor.pngData(from: image)!
    }
}
