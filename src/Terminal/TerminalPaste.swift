import Foundation

public enum TerminalPastePayload: Equatable, Sendable {
    case text(String)
    case image(URL)
}

public protocol PastedImageStoring {
    func savePNGData(_ data: Data, role: TerminalRole) throws -> URL
}

public struct YAAWPastedImageStore: PastedImageStoring {
    public let rootDirectory: URL
    private let fileManager: FileManager

    public init(
        rootDirectory: URL = YAAWPastedImageStore.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("YAAW", isDirectory: true)
            .appendingPathComponent("PastedImages", isDirectory: true)
    }

    public func savePNGData(_ data: Data, role: TerminalRole) throws -> URL {
        let directory = rootDirectory
            .appendingPathComponent(role.storageComponent, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

public struct TerminalPasteTextFormatter: Sendable {
    public init() {}

    public func text(for payload: TerminalPastePayload, agentCLI: AgentCLIKind) -> String {
        switch payload {
        case .text(let text):
            return text
        case .image(let url):
            return agentCLI.imagePasteText(for: url)
        }
    }
}

private extension TerminalRole {
    var storageComponent: String {
        switch self {
        case .project(let threadID):
            return "project-\(threadID.uuidString)"
        case .bottom(let threadID):
            return "bottom-\(threadID.uuidString)"
        case .nvim(let threadID):
            return "nvim-\(threadID.uuidString)"
        case .nvimTab(let threadID, let tabID):
            return "nvim-\(threadID.uuidString)-\(tabID)"
        case .lazygit(let threadID):
            return "git-\(threadID.uuidString)"
        }
    }
}

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

public enum TerminalPasteShortcut {
    public static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
              event.modifierFlags.isDisjoint(with: [.option, .shift])
        else {
            return false
        }
        return true
    }
}

public enum PasteboardImageExtractor {
    public static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) {
            return data
        }
        if let data = pasteboard.data(forType: .tiff),
           let png = pngData(fromImageData: data) {
            return png
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]),
           let image = images.compactMap({ $0 as? NSImage }).first,
           let png = pngData(from: image) {
            return png
        }
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in fileURLs {
                guard let image = NSImage(contentsOf: url),
                      let png = pngData(from: image) else { continue }
                return png
            }
        }
        if let data = pasteboard.data(forType: .rtfd),
           let png = pngDataFromRTFDAttachment(data) {
            return png
        }
        return nil
    }

    public static func pngData(from image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }

    private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return pngData(from: image)
    }

    private static func pngDataFromRTFDAttachment(_ data: Data) -> Data? {
        guard let wrapper = FileWrapper(serializedRepresentation: data) else { return nil }
        return pngData(from: wrapper)
    }

    private static func pngData(from wrapper: FileWrapper) -> Data? {
        if wrapper.isRegularFile,
           let data = wrapper.regularFileContents,
           let png = pngData(fromImageData: data) {
            return png
        }
        guard let wrappers = wrapper.fileWrappers else { return nil }
        for child in wrappers.values {
            if let png = pngData(from: child) {
                return png
            }
        }
        return nil
    }
}
#endif
