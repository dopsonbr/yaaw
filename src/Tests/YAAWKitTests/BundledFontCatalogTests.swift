import CoreText
import XCTest

@testable import YAAWKit

final class BundledFontCatalogTests: XCTestCase {
    func testRegisterBundledFontsMakesJetBrainsMonoResolvable() {
        XCTAssertTrue(BundledFontCatalog.registerBundledFonts())

        let font = CTFontCreateWithName("JetBrainsMono-Regular" as CFString, 13, nil)
        let postScriptName = CTFontCopyPostScriptName(font) as String
        XCTAssertEqual(postScriptName, "JetBrainsMono-Regular")

        let familyName = CTFontCopyFamilyName(font) as String
        XCTAssertEqual(familyName, BundledFontCatalog.jetBrainsMonoFamily)
    }

    func testRegisterBundledFontsIsIdempotent() {
        XCTAssertTrue(BundledFontCatalog.registerBundledFonts())
        XCTAssertTrue(BundledFontCatalog.registerBundledFonts())
    }

    func testBundledFacesCoverEditorAndTerminalWeights() {
        XCTAssertTrue(BundledFontCatalog.registerBundledFonts())

        for postScriptName in [
            "JetBrainsMono-Regular",
            "JetBrainsMono-Italic",
            "JetBrainsMono-Medium",
            "JetBrainsMono-SemiBold",
            "JetBrainsMono-Bold",
            "JetBrainsMono-BoldItalic",
        ] {
            let font = CTFontCreateWithName(postScriptName as CFString, 13, nil)
            XCTAssertEqual(
                CTFontCopyPostScriptName(font) as String,
                postScriptName,
                "Expected bundled face \(postScriptName) to resolve"
            )
        }
    }
}
