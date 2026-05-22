import AppKit
import UserNotifications
import YAAWKit

@MainActor
final class MacSystemThreadActivityNotificationDispatcher: ThreadActivityNotificationDispatching {
    static let shared = MacSystemThreadActivityNotificationDispatcher()

    private let center = UNUserNotificationCenter.current()
    private var hasRequestedAuthorization = false

    private init() {}

    nonisolated func dispatch(_ notification: ThreadActivityNotification) {
        Task { @MainActor in
            await self.dispatchOnMainActor(notification)
        }
    }

    private func dispatchOnMainActor(_ notification: ThreadActivityNotification) async {
        if !hasRequestedAuthorization {
            hasRequestedAuthorization = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "thread-activity-\(notification.threadID.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

@MainActor
final class MacDockThreadActivityBadgeUpdater: ThreadActivityBadgeUpdating {
    static let shared = MacDockThreadActivityBadgeUpdater()

    private init() {}

    nonisolated func updateUnreadThreadActivityCount(_ count: Int) {
        Task { @MainActor in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }
}
