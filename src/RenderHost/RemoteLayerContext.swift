import Foundation
import QuartzCore

/// Wraps a `CALayer` (the Ghostty surface's `CAMetalLayer`) in a QuartzCore
/// `CAContext` so its layer tree can be hosted in another process, and exposes
/// the small integer `contextID` the app uses with `CALayerHost` to composite
/// the helper's output natively inside a pane (ADR-004, Candidate 1).
///
/// `CAContext` is the exact remote-layer mechanism WebKit/QuickLook/video use;
/// it is QuartzCore SPI with no public Swift overlay, so we describe the slice
/// we need as an `@objc` protocol and resolve the real class through the
/// Objective-C runtime. No per-frame pixel data crosses the XPC boundary — the
/// window server shares the layer tree; the app only needs the `contextID`.
@MainActor
final class RemoteLayerContext {
    /// The published context identifier the app hosts with `CALayerHost`.
    let contextID: UInt32

    private let context: NSObject

    /// Creates a remote-hosting context over `layer`, or returns `nil` if the
    /// `CAContext` SPI is unavailable (the helper then reports `contextID == 0`
    /// and the app keeps the pane in a non-composited state rather than crash).
    init?(layer: CALayer) {
        guard let contextClass = NSClassFromString("CAContext") else { return nil }
        let selector = NSSelectorFromString("localContextWithOptions:")
        guard let metaClass = object_getClass(contextClass),
            let method = class_getClassMethod(metaClass, selector)
        else { return nil }

        let implementation = method_getImplementation(method)
        let factory = unsafeBitCast(implementation, to: LocalContextFactory.self)
        guard let created = factory(contextClass, selector, nil) as? NSObject else { return nil }

        self.context = created
        // `layer` and `contextID` are KVC-compliant `@objc` properties on the
        // real CAContext; setValue/typed-cast read avoid hand-rolling more IMPs.
        created.setValue(layer, forKey: "layer")
        self.contextID = (created as? CAContextLayerHosting)?.contextID ?? 0
    }

    /// Re-points the context at `layer` after the surface rebuilds its
    /// `CAMetalLayer` (e.g. an IOSurface-backed swap on a backing-scale change),
    /// keeping the published `contextID` stable across the swap.
    func attach(layer: CALayer) {
        context.setValue(layer, forKey: "layer")
    }

    /// `+[CAContext localContextWithOptions:]` resolved via the runtime.
    private typealias LocalContextFactory =
        @convention(c) (AnyObject, Selector, NSDictionary?) -> AnyObject?
}

/// The read slice of `CAContext` we consume. Declared `@objc` so the cast binds
/// to the real class's `contextID` getter at runtime.
@objc private protocol CAContextLayerHosting {
    var contextID: UInt32 { get }
}
