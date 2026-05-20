import Foundation

public struct FileBrowserEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let isDirectory: Bool

    public init(relativePath: String, isDirectory: Bool) {
        self.id = relativePath
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }
}

public enum SampleFileBrowser {
    public static let sampleEntries: [FileBrowserEntry] = [
        FileBrowserEntry(relativePath: ".env.example", isDirectory: false),
        FileBrowserEntry(relativePath: "README.md", isDirectory: false),
        FileBrowserEntry(relativePath: "src", isDirectory: true),
        FileBrowserEntry(relativePath: "docs", isDirectory: true)
    ]
}
