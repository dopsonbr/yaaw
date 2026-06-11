import Foundation

extension Array where Element == String {
    internal var nonBlankValues: [String] {
        map(\.trimmed).filter { !$0.isEmpty }
    }
}

extension String {
    internal var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    internal var configurationNilIfBlank: String? {
        let value = trimmed
        return value.isEmpty || value == AgentLaunchOptions.defaultPermissionModeID ? nil : value
    }

    internal func nonBlankOr(_ fallback: String) -> String {
        let value = trimmed
        return value.isEmpty ? fallback : value
    }
}

extension Double {
    internal func clampedFontSize(defaultValue: Double, minimum: Double, maximum: Double)
        -> Double
    {
        guard isFinite else { return defaultValue }
        return min(max(self, minimum), maximum)
    }

    internal var formattedFontSize: String {
        formatted(.number.precision(.fractionLength(0...2)))
    }
}
