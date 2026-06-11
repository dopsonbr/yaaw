import Foundation

/// Policy for what bytes to inject when an image is pasted into a terminal.
///
/// Every agent CLI receives the native attachment shortcut (`Ctrl-V`,
/// `"\u{16}"`) rather than a filesystem path, so a pasted image is handed to the
/// CLI's own image-attachment flow and no local path is leaked into the prompt.
public struct TerminalImagePastePolicy: Sendable {
    /// The control character the CLIs interpret as "attach the pasteboard image".
    public static let nativeAttachmentShortcutText = "\u{16}"

    /// Creates an image-paste policy.
    public init() {}

    /// The text to inject for an image paste, for the given CLI.
    public func textForImagePaste(agentCLI _: AgentCLIKind) -> String {
        Self.nativeAttachmentShortcutText
    }
}

#if canImport(AppKit)
    import AppKit
    import UniformTypeIdentifiers

    /// Matches the keyboard event that should trigger a terminal paste.
    public enum TerminalPasteShortcut {
        /// True for `Cmd-V` or `Ctrl-V` key-downs (no Option/Shift modifiers).
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

    /// Extracts PNG image data from a pasteboard for image-paste handling.
    public enum PasteboardImageExtractor {
        /// Returns PNG data for the first image found on `pasteboard`, if any.
        ///
        /// Tries, in order: a direct PNG, a TIFF (converted), an `NSImage`
        /// object, an image file URL, then an RTFD attachment.
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

        /// Renders `image` to PNG data, or `nil` if it cannot be rasterized.
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
