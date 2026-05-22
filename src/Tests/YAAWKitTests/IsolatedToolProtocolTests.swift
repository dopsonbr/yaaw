import XCTest

@testable import YAAWKit

final class IsolatedToolProtocolTests: XCTestCase {
    func testEnvelopeRoundTripsVersionedCommand() throws {
        let envelope = IsolatedToolEnvelope(
            toolKind: .browser,
            instanceID: "thread:browser",
            messageID: "message-1",
            type: "load",
            payload: ["urlString": "file:///tmp/index.html"]
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IsolatedToolEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testEnvelopeRejectsUnsupportedProtocolVersion() throws {
        let envelope = IsolatedToolEnvelope(
            protocolVersion: 999,
            toolKind: .browser,
            instanceID: "thread:browser",
            type: "load"
        )

        XCTAssertThrowsError(try envelope.validated()) { error in
            XCTAssertEqual(error as? IsolatedToolProtocolError, .unsupportedProtocolVersion(999))
        }
    }

    func testRuntimeReducerTracksBrowserStateAndCrash() {
        var snapshot = IsolatedToolRuntimeSnapshot()

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .launch)
        XCTAssertEqual(snapshot.phase, .launching)

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .ready)
        XCTAssertEqual(snapshot.phase, .ready)

        snapshot = IsolatedToolRuntimeReducer.reduce(
            snapshot,
            action: .stateChanged([
                "title": "Preview",
                "urlString": "file:///tmp/index.html",
                "isLoading": "true",
                "canGoBack": "true",
                "canGoForward": "false",
            ])
        )
        XCTAssertEqual(snapshot.phase, .loading)
        XCTAssertEqual(snapshot.title, "Preview")
        XCTAssertEqual(snapshot.urlString, "file:///tmp/index.html")
        XCTAssertTrue(snapshot.isLoading)
        XCTAssertTrue(snapshot.canGoBack)
        XCTAssertFalse(snapshot.canGoForward)

        snapshot = IsolatedToolRuntimeReducer.reduce(snapshot, action: .crashed("renderer exited"))
        XCTAssertEqual(snapshot.phase, .crashed)
        XCTAssertEqual(snapshot.errorMessage, "renderer exited")
        XCTAssertFalse(snapshot.isLoading)
    }
}
