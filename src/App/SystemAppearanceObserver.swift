import AppKit
import Combine

/// Watches the application's effective appearance and reports light/dark flips.
/// KVO on `NSApplication.effectiveAppearance` is preferred over the distributed
/// "AppleInterfaceThemeChangedNotification" (undocumented, and can fire before
/// `effectiveAppearance` updates) and over SwiftUI's `colorScheme` environment
/// (which the app overrides per theme, making it circular here).
@MainActor
final class SystemAppearanceObserver {
    private var cancellable: AnyCancellable?

    func install(onChange: @escaping (Bool) -> Void) {
        cancellable = NSApplication.shared.publisher(for: \.effectiveAppearance)
            .map { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
            .removeDuplicates()
            .sink(receiveValue: onChange)
    }
}
