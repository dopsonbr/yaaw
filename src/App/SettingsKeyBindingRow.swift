import SwiftUI
import YAAWKit

struct SettingsKeyBindingRow: View {
    let action: KeyboardShortcutAction
    let definition: KeyboardShortcutDefinition
    let isConflicting: Bool
    let onSetKey: (String) -> Void
    let onToggleModifier: (KeyboardShortcutModifier) -> Void
    let onClear: () -> Void
    let onReset: () -> Void
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                    .font(fonts.interfaceFont(weight: .semibold))
                    .lineLimit(1)
                Text(action.rawValue)
                    .font(fonts.editorFont(sizeOffset: -2))
                    .foregroundStyle(dracula(.comment))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(action.scope.rawValue)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
                .frame(width: 110, alignment: .leading)

            HStack(spacing: 6) {
                TextField("Key", text: keyBinding)
                    .textFieldStyle(.plain)
                    .font(fonts.editorFont())
                    .frame(width: 46)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(dracula(.currentLine))
                    .accessibilityLabel("\(action.displayName) key")

                Text(definition.displayText)
                    .font(fonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(isConflicting ? dracula(.red) : dracula(.foreground))
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)

            Text(action.defaultShortcutDescription)
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(dracula(.comment))
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(KeyboardShortcutModifier.allCases, id: \.self) { modifier in
                    Toggle(modifier.shortName, isOn: modifierBinding(modifier))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
            .frame(width: 260, alignment: .leading)

            HStack(spacing: 6) {
                Button("Clear", action: onClear)
                Button("Default", action: onReset)
            }
            .controlSize(.small)
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isConflicting ? dracula(.red).opacity(0.18) : dracula(.currentLine).opacity(0.25)
        )
        .accessibilityIdentifier("settings-keybinding-\(action.rawValue)")
    }

    private var keyBinding: Binding<String> {
        Binding(
            get: { definition.key },
            set: { onSetKey($0) }
        )
    }

    private func modifierBinding(_ modifier: KeyboardShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { definition.modifiers.contains(modifier) },
            set: { _ in onToggleModifier(modifier) }
        )
    }
}

extension KeyboardShortcutModifier {
    fileprivate var shortName: String {
        switch self {
        case .command:
            "Cmd"
        case .shift:
            "Shift"
        case .option:
            "Opt"
        case .control:
            "Ctrl"
        }
    }
}
