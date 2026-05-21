import Foundation
import XCTest
@testable import YAAWKit

final class ProjectThreadModelTests: XCTestCase {
    func testProjectPreservesPublicMetadata() {
        let id = UUID()
        let rootDirectory = URL(fileURLWithPath: "/tmp/sample-project", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 100)
        let lastOpenedAt = Date(timeIntervalSince1970: 200)

        let project = Project(
            id: id,
            displayName: "Sample",
            rootDirectory: rootDirectory,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt
        )

        XCTAssertEqual(project.id, id)
        XCTAssertEqual(project.displayName, "Sample")
        XCTAssertEqual(project.rootDirectory, rootDirectory)
        XCTAssertEqual(project.createdAt, createdAt)
        XCTAssertEqual(project.lastOpenedAt, lastOpenedAt)
    }

    func testAgentThreadPreservesPublicMetadataAndArchiveState() {
        let id = UUID()
        let projectID = UUID()
        let workingDirectory = URL(fileURLWithPath: "/tmp/sample-project/worktree", isDirectory: true)
        let createdAt = Date(timeIntervalSince1970: 300)
        let lastOpenedAt = Date(timeIntervalSince1970: 400)

        let thread = AgentThread(
            id: id,
            displayName: "Feature Thread",
            projectID: projectID,
            workingDirectory: workingDirectory,
            createdAt: createdAt,
            lastOpenedAt: lastOpenedAt,
            isArchived: true
        )

        XCTAssertEqual(thread.id, id)
        XCTAssertEqual(thread.displayName, "Feature Thread")
        XCTAssertEqual(thread.projectID, projectID)
        XCTAssertEqual(thread.workingDirectory, workingDirectory)
        XCTAssertEqual(thread.createdAt, createdAt)
        XCTAssertEqual(thread.lastOpenedAt, lastOpenedAt)
        XCTAssertTrue(thread.isArchived)
    }
}
