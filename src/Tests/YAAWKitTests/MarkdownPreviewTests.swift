import XCTest

@testable import YAAWKit

final class MarkdownPreviewTests: XCTestCase {
    func testRendererBuildsHTMLForMarkdownAndMermaid() {
        let html = MarkdownPreviewRenderer.renderHTML(
            markdown: """
                # Architecture

                See [guide](docs/guide.md).

                ```mermaid
                graph TD
                  A[Start] --> B[Done]
                ```
                """,
            sourceURL: URL(fileURLWithPath: "/tmp/project/README.md")
        )

        XCTAssertTrue(html.contains("<h1 id=\"architecture\">Architecture</h1>"))
        XCTAssertTrue(html.contains("<a href=\"docs/guide.md\">guide</a>"))
        XCTAssertTrue(html.contains("class=\"mermaid-card\""))
        XCTAssertTrue(html.contains("renderFlowchart"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
    }

    func testRendererSanitizesUnsafeHTML() {
        let html = MarkdownPreviewRenderer.renderHTML(
            markdown: """
                <script>alert(1)</script>
                <a href="javascript:alert(1)" onclick="alert(1)">bad</a>
                <strong>ok</strong>
                """,
            sourceURL: URL(fileURLWithPath: "/tmp/project/README.md")
        )

        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertFalse(html.contains("javascript:alert"))
        XCTAssertFalse(html.contains("onclick"))
        XCTAssertTrue(html.contains("<strong>ok</strong>"))
    }

    func testMarkdownURLDetectionIsCaseInsensitiveForFileURLs() {
        XCTAssertTrue(MarkdownPreviewRenderer.isMarkdownURL(URL(fileURLWithPath: "/tmp/README.MD")))
        XCTAssertTrue(
            MarkdownPreviewRenderer.isMarkdownURL(URL(fileURLWithPath: "/tmp/docs/file.markdown")))
        XCTAssertFalse(
            MarkdownPreviewRenderer.isMarkdownURL(URL(fileURLWithPath: "/tmp/index.html")))
        XCTAssertFalse(
            MarkdownPreviewRenderer.isMarkdownURL(URL(string: "https://example.com/README.md")!))
    }
}
