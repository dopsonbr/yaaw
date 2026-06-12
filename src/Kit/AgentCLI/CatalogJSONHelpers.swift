import Foundation
import Synchronization

/// Pure helpers for reading values out of decoded JSON objects by key.
///
/// `firstString`/`firstURL`/`firstDate` recurse into nested objects/arrays so a
/// generic key (e.g. `cwd`) can be found wherever the CLI nests it.
/// `topLevelString` reads only the object's own top level — use it for keys that
/// are ambiguous inside nested message/tool content (e.g. claude's `customTitle`).
enum CatalogJSON {
    /// A single shared ISO-8601 parser. `ISO8601DateFormatter` allocation spins up
    /// ICU locale data, which is ruinous when done per JSONL line across a large
    /// session catalog (it pegged startup on big projects like order-up). One
    /// reused instance behind a `Mutex` keeps parsing concurrency-safe (the
    /// formatter is mutable C state) without per-call allocation. `Mutex` is
    /// `Sendable`, so this stays a clean `static let` under strict concurrency —
    /// no `@unchecked Sendable`, no `nonisolated(unsafe)`.
    private static let iso8601Formatter = Mutex(ISO8601DateFormatter())

    /// Decodes a single JSON document from `url`.
    static func object(from url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Decodes the non-blank lines of a JSONL file at `url`, skipping
    /// unparseable lines (resilient to partial corruption).
    static func objects(fromJSONL url: URL) -> [Any] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }

    /// The first non-`nil` string found for any of `keys`, searched recursively.
    static func firstString(in object: Any, keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(in: object, key: key) {
                return value
            }
        }
        return nil
    }

    /// Reads `key` only from the object's own top-level dictionary (no recursion).
    static func topLevelString(in object: Any, key: String) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        for (candidateKey, value) in dictionary
        where candidateKey.caseInsensitiveCompare(key) == .orderedSame {
            if let string = coercedString(value) {
                return string
            }
        }
        return nil
    }

    /// The first URL parsed from any of `keys` (searched recursively).
    static func firstURL(in object: Any, keys: [String]) -> URL? {
        firstString(in: object, keys: keys).flatMap(url(fromPath:))
    }

    /// The first date parsed from any of `keys` (searched recursively).
    static func firstDate(in object: Any, keys: [String]) -> Date? {
        for key in keys {
            if let date = dateValue(in: object, key: key) {
                return date
            }
        }
        return nil
    }

    /// The file's last-modification date, if available.
    static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Recursive primitives

    private static func stringValue(in object: Any, key: String) -> String? {
        if let dictionary = object as? [String: Any] {
            for (candidateKey, value) in dictionary
            where candidateKey.caseInsensitiveCompare(key) == .orderedSame {
                if let string = coercedString(value) {
                    return string
                }
            }
            for value in dictionary.values {
                if let nested = stringValue(in: value, key: key) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = stringValue(in: value, key: key) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func dateValue(in object: Any, key: String) -> Date? {
        if let dictionary = object as? [String: Any] {
            for (candidateKey, value) in dictionary
            where candidateKey.caseInsensitiveCompare(key) == .orderedSame {
                if let date = coercedDate(value) {
                    return date
                }
            }
            for value in dictionary.values {
                if let nested = dateValue(in: value, key: key) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = dateValue(in: value, key: key) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func coercedString(_ value: Any) -> String? {
        if let string = value as? String {
            return string.agentCLINilIfBlank
        }
        if let number = value as? NSNumber {
            return number.stringValue.agentCLINilIfBlank
        }
        return nil
    }

    private static func coercedDate(_ value: Any) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        guard let string = coercedString(value) else { return nil }
        if let numeric = Double(string) {
            return Date(
                timeIntervalSince1970: numeric > 1_000_000_000_000 ? numeric / 1000 : numeric)
        }
        return iso8601Formatter.withLock { $0.date(from: string) }
    }

    private static func url(fromPath path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded =
            trimmed == "~" || trimmed.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.path + String(trimmed.dropFirst())
            : trimmed
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
