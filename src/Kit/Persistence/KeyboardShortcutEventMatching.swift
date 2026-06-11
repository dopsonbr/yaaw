#if canImport(AppKit)
    import AppKit

    extension KeyboardShortcutDefinition {
        public func matches(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, isBound, isValid else { return false }
            guard event.yaawShortcutKey == normalizedKey else { return false }
            return Set(modifiers) == event.yaawShortcutModifiers
        }
    }

    extension NSEvent {
        public var yaawShortcutKey: String? {
            let rawKey = charactersIgnoringModifiers ?? characters
            let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let key, key.count == 1 else { return nil }
            if modifierFlags.contains(.shift),
                let unshiftedKey = Self.yaawUnshiftedPunctuation[key]
            {
                return unshiftedKey
            }
            return key
        }

        public var yaawShortcutModifiers: Set<KeyboardShortcutModifier> {
            var shortcutModifiers: Set<KeyboardShortcutModifier> = []
            let relevantFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            if relevantFlags.contains(.command) {
                shortcutModifiers.insert(.command)
            }
            if relevantFlags.contains(.shift) {
                shortcutModifiers.insert(.shift)
            }
            if relevantFlags.contains(.option) {
                shortcutModifiers.insert(.option)
            }
            if relevantFlags.contains(.control) {
                shortcutModifiers.insert(.control)
            }
            return shortcutModifiers
        }

        private static let yaawUnshiftedPunctuation: [String: String] = [
            "{": "[",
            "}": "]",
            "<": ",",
            ">": ".",
        ]
    }
#endif
