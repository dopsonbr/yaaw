import AppKit
import Foundation
import YAAWKit

// The render helper is a faceless accessory process: it hosts a libghostty
// surface or a WKWebView and composites into the app's pane via a remote
// CAContext (ADR-004). It owns no visible window and must never steal focus
// (the E2E `frontmost` check asserts this), so it sets the accessory activation
// policy before doing anything else.
//
// Ghostty discovers fonts through CoreText inside *this* process; process-scope
// font registrations do not cross the XPC boundary, so the helper re-registers
// the bundled JetBrains Mono just like the app does.
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    BundledFontCatalog.registerBundledFonts(
        diagnosticRecorder: LoggerDiagnosticEventRecorder.shared
    )
}

let listener = NSXPCListener.service()
let delegate = RenderServiceDelegate()
listener.delegate = delegate
listener.resume()

// `NSXPCListener.service()` runs its own dispatch loop and never returns; the
// AppKit run loop keeps the main thread alive so the Ghostty surface (which is
// main-thread-only) and its display-link ticks have a runloop to schedule on.
NSApplication.shared.run()
