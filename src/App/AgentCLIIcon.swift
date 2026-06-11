import AppKit
import SwiftUI
import YAAWKit

/// Brand icon for an agent CLI, loaded from the app's bundled `AgentIcons`
/// resources with an SF Symbol fallback. Used by the sidebar rows and the new
/// thread sheet.
struct AgentCLIIcon: View {
    let agentCLI: AgentCLIKind

    var body: some View {
        if let image = bundledImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: agentCLI.fallbackSystemSymbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dracula(.cyan))
        }
    }

    private var bundledImage: NSImage? {
        for fileExtension in agentCLI.brandIconResourceExtensions {
            for bundle in Self.resourceBundles {
                if let image = image(in: bundle, fileExtension: fileExtension, subdirectory: nil) {
                    return image
                }
                if let image = image(
                    in: bundle, fileExtension: fileExtension, subdirectory: "AgentIcons")
                {
                    return image
                }
            }
        }
        return nil
    }

    private static var resourceBundles: [Bundle] {
        var bundles = [Bundle.main, Bundle.module]
        if let resourcesURL = Bundle.main.resourceURL {
            let swiftPMBundleURL = resourcesURL.appendingPathComponent(
                "YAAW_YAAW.bundle", isDirectory: true)
            if let bundle = Bundle(url: swiftPMBundleURL) {
                bundles.append(bundle)
            }
        }
        return bundles
    }

    private func image(in bundle: Bundle, fileExtension: String, subdirectory: String?) -> NSImage?
    {
        guard
            let url = bundle.url(
                forResource: agentCLI.brandIconResourceName,
                withExtension: fileExtension,
                subdirectory: subdirectory
            )
        else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
