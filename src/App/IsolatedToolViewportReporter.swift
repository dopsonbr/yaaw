import AppKit
import SwiftUI

struct IsolatedToolViewportReporter: NSViewRepresentable {
    let onViewportChanged: (CGRect, Bool) -> Void

    func makeNSView(context: Context) -> ViewportView {
        let view = ViewportView()
        view.onViewportChanged = onViewportChanged
        return view
    }

    func updateNSView(_ nsView: ViewportView, context: Context) {
        nsView.onViewportChanged = onViewportChanged
        nsView.report()
    }

    final class ViewportView: NSView {
        var onViewportChanged: ((CGRect, Bool) -> Void)?

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
                onViewportChanged?(.zero, false)
                updateReportTimer()
                return
            }
            let windowRect = convert(bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            let visible =
                !isHiddenOrHasHiddenAncestor
                && window.isVisible
                && NSApp.isActive
                && screenRect.width > 1
                && screenRect.height > 1
            onViewportChanged?(screenRect, visible)
        }
    }
}
