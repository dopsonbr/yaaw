import SwiftUI

/// Shared sizing, spacing, and weight tokens for the app chrome.
///
/// Centralizing the handful of values we actually reuse keeps the toolbar,
/// sidebar, and right-panel tabs visually consistent. The biggest lever here is
/// `glyphWeight`: rendering chrome SF Symbols at `.medium` (instead of the old
/// `.semibold`) is what makes the UI read as quiet/native rather than heavy.
enum ChromeMetrics {
    // Icon button hit targets.
    static let toolbarButton: CGFloat = 28
    static let sidebarButton: CGFloat = 20

    // SF Symbol point sizes for chrome glyphs.
    static let toolbarGlyph: CGFloat = 15
    static let sidebarGlyph: CGFloat = 13
    static let statusGlyph: CGFloat = 12

    // Selection / hover treatment.
    static let selectionCornerRadius: CGFloat = 6
    static let rowHInset: CGFloat = 4

    // Default chrome symbol weight.
    static let glyphWeight: Font.Weight = .medium

    /// Selection pill fill for a row/control given its selected/hovered state.
    static func pillFill(selected: Bool, hovering: Bool) -> AnyShapeStyle {
        if selected {
            return AnyShapeStyle(dracula(.currentLine))
        }
        if hovering {
            return AnyShapeStyle(dracula(.currentLine).opacity(0.4))
        }
        return AnyShapeStyle(Color.clear)
    }
}

/// Uniform chrome icon button: consistent hit target, medium glyph weight, and a
/// subtle rounded hover background. All toolbar / collapsed-rail buttons route
/// through this so nothing in the chrome looks mismatched.
struct ChromeIconButton: View {
    let systemImage: String
    var size: CGFloat = ChromeMetrics.toolbarButton
    var glyph: CGFloat = ChromeMetrics.toolbarGlyph
    var tint: AppThemeColor = dracula(.foreground)
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyph, weight: ChromeMetrics.glyphWeight))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.selectionCornerRadius)
                        .fill(ChromeMetrics.pillFill(selected: false, hovering: hovering))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
