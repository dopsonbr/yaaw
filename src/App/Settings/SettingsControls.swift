import SwiftUI
import YAAWKit

/// Labeled grid row used by the settings sections: trailing-aligned title
/// column and a leading-aligned content column.
struct SettingsGridRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        GridRow {
            Text(title)
                .font(fonts.interfaceFont(sizeOffset: -1, weight: .semibold))
                .foregroundStyle(themeUI(.secondaryLabel))
                .frame(width: 150, alignment: .trailing)

            content
                .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct SettingsMenuControlModifier: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.fontSettings) private var fonts

    func body(content: Content) -> some View {
        content
            .labelsHidden()
            .pickerStyle(.menu)
            .font(fonts.interfaceFont(sizeOffset: -1, weight: .medium))
            .foregroundStyle(themeUI(.controlForeground))
            .tint(themeUI(.focusAccent))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: maxWidth, minHeight: 30, alignment: .leading)
            .background(themeUI(.controlBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(themeUI(.controlBorder), lineWidth: 1)
            )
    }
}

extension View {
    func settingsMenuControl(maxWidth: CGFloat) -> some View {
        modifier(SettingsMenuControlModifier(maxWidth: maxWidth))
    }

    @ViewBuilder
    func configuredKeyboardShortcut(_ definition: KeyboardShortcutDefinition) -> some View {
        if definition.isBound, let character = definition.key.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: definition.eventModifiers)
        } else {
            self
        }
    }
}

extension KeyboardShortcutDefinition {
    var eventModifiers: EventModifiers {
        var eventModifiers = EventModifiers()
        for modifier in modifiers {
            switch modifier {
            case .command:
                eventModifiers.insert(.command)
            case .shift:
                eventModifiers.insert(.shift)
            case .option:
                eventModifiers.insert(.option)
            case .control:
                eventModifiers.insert(.control)
            }
        }
        return eventModifiers
    }
}
