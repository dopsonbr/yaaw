import AppKit
import Darwin
import SwiftUI

struct IsolatedToolViewportReporter: NSViewRepresentable {
    /// Emits the viewport frame, whether the helper should be visible, and
    /// whether its window should stay above the parent app's normal content.
    let onViewportChanged: (CGRect, Bool, Bool) -> Void
    var allowsToolHostFrontmostVisibility = false
    var allowsInactiveApplicationVisibility = false
    var hidesWhenWindowHasAttachedSheet = false

    func makeNSView(context: Context) -> ViewportView {
        let view = ViewportView()
        view.onViewportChanged = onViewportChanged
        view.allowsToolHostFrontmostVisibility = allowsToolHostFrontmostVisibility
        view.allowsInactiveApplicationVisibility = allowsInactiveApplicationVisibility
        view.hidesWhenWindowHasAttachedSheet = hidesWhenWindowHasAttachedSheet
        return view
    }

    func updateNSView(_ nsView: ViewportView, context: Context) {
        nsView.onViewportChanged = onViewportChanged
        nsView.allowsToolHostFrontmostVisibility = allowsToolHostFrontmostVisibility
        nsView.allowsInactiveApplicationVisibility = allowsInactiveApplicationVisibility
        nsView.hidesWhenWindowHasAttachedSheet = hidesWhenWindowHasAttachedSheet
        nsView.report()
    }

    func allowsToolHostFrontmostVisibility(_ allowed: Bool) -> Self {
        var copy = self
        copy.allowsToolHostFrontmostVisibility = allowed
        return copy
    }

    func allowsInactiveApplicationVisibility(_ allowed: Bool) -> Self {
        var copy = self
        copy.allowsInactiveApplicationVisibility = allowed
        return copy
    }

    func hidesWhenWindowHasAttachedSheet(_ hides: Bool) -> Self {
        var copy = self
        copy.hidesWhenWindowHasAttachedSheet = hides
        return copy
    }

    final class ViewportView: NSView {
        var onViewportChanged: ((CGRect, Bool, Bool) -> Void)?
        var allowsToolHostFrontmostVisibility = false
        var allowsInactiveApplicationVisibility = false
        var hidesWhenWindowHasAttachedSheet = false

        deinit {
            NotificationCenter.default.removeObserver(self)
            NSObject.cancelPreviousPerformRequests(withTarget: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureNotificationObservers()
            updateReportTimer()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        private func updateReportTimer() {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            guard window != nil else { return }
            perform(#selector(reportFromTimer), with: nil, afterDelay: 0.15, inModes: [.common])
        }

        private func configureNotificationObservers() {
            NotificationCenter.default.removeObserver(self)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(reportFromNotification),
                name: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )
            center.addObserver(
                self,
                selector: #selector(reportFromNotification),
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )

            guard let window else { return }
            for name in [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ] {
                center.addObserver(
                    self,
                    selector: #selector(reportFromNotification),
                    name: name,
                    object: window
                )
            }
        }

        @objc private func reportFromNotification(_ notification: Notification) {
            report()
        }

        @objc private func reportFromTimer() {
            guard window != nil else {
                updateReportTimer()
                return
            }
            report()
            perform(#selector(reportFromTimer), with: nil, afterDelay: 0.15, inModes: [.common])
        }

        func report() {
            guard let window else {
                onViewportChanged?(.zero, false, NSApp.isActive)
                updateReportTimer()
                return
            }
            let windowRect = convert(bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            let visible =
                !isHiddenOrHasHiddenAncestor
                && window.isVisible
                && isApplicationVisibleForToolHost
                && !isBlockedByAttachedWindow(over: screenRect)
                && !isCoveredBySiblingWindow(over: screenRect)
                && screenRect.width > 1
                && screenRect.height > 1
            onViewportChanged?(screenRect, visible, isApplicationClusterFrontmost)
        }

        /// A sheet on the pane's own window always blocks (the whole window is
        /// interaction-blocked, and the floating helper would look live above
        /// it). An app-modal window only blocks the panes it actually covers —
        /// hiding every terminal for any dialog anywhere was a bug.
        private func isBlockedByAttachedWindow(over screenRect: CGRect) -> Bool {
            guard hidesWhenWindowHasAttachedSheet else { return false }
            if window?.attachedSheet != nil { return true }
            guard let modalWindow = NSApp.modalWindow else { return false }
            return modalWindow.frame.intersects(screenRect)
        }

        /// The helpers render in floating-level windows above every normal
        /// window, so a sibling window of this app (e.g. the Settings window)
        /// ordered in front of the pane's window would otherwise show the
        /// helper tearing through it. Windows above the normal level (menus,
        /// tooltips) already draw over the helpers and must not blank panes.
        private func isCoveredBySiblingWindow(over screenRect: CGRect) -> Bool {
            guard let window else { return false }
            for other in NSApp.orderedWindows {
                if other == window { return false }
                if other.level == .normal, other.isVisible,
                    other.frame.intersects(screenRect)
                {
                    return true
                }
            }
            return false
        }

        private var isApplicationVisibleForToolHost: Bool {
            if allowsInactiveApplicationVisibility {
                return true
            }
            return isApplicationClusterFrontmost
        }

        private var isApplicationClusterFrontmost: Bool {
            guard allowsToolHostFrontmostVisibility else {
                return NSApp.isActive
            }
            guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
                return NSApp.isActive
            }
            if frontmostApplication.processIdentifier == getpid() {
                return true
            }
            return frontmostApplication.executableURL?.lastPathComponent == "YAAWToolHost"
        }
    }
}
