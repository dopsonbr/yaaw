import Foundation

public struct TerminalImagePastePolicy: Sendable {
    public static let nativeAttachmentShortcutText = "\u{16}"

    public init() {}

    public func textForImagePaste(agentCLI _: AgentCLIKind) -> String {
        Self.nativeAttachmentShortcutText
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
                let png = pngData(fromImageData: data)
            {
                return png
            }
            if let images = pasteboard.readObjects(forClasses: [NSImage.self]),
                let image = images.compactMap({ $0 as? NSImage }).first,
                let png = pngData(from: image)
            {
                return png
            }
            if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
                for url in fileURLs {
                    guard let image = NSImage(contentsOf: url),
                        let png = pngData(from: image)
                    else { continue }
                    return png
                }
            }
            if let data = pasteboard.data(forType: .rtfd),
                let png = pngDataFromRTFDAttachment(data)
            {
                return png
            }
            return nil
        }

        public static func pngData(from image: NSImage) -> Data? {
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            else {
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
                let png = pngData(fromImageData: data)
            {
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
