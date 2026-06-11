import AppKit
import SwiftUI
import YAAWKit

struct AppearanceSettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.fontSettings) private var fonts

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                SettingsGridRow(title: "Theme") {
                    Picker("Theme", selection: model.themeSelection) {
                        Text("System (match macOS)").tag(ThemeSettings.systemActiveID)
                        ForEach(ThemeGroup.allCases) { group in
                            Section(group.displayName) {
                                ForEach(ThemeCatalog.themes(in: group)) { theme in
                                    Text(theme.displayName).tag(theme.id)
                                }
                            }
                        }
                    }
                    .settingsMenuControl(maxWidth: 360)
                    .accessibilityLabel("Theme")
                    .accessibilityIdentifier("settings-theme-picker")
                }

                if model.selectedThemeID == ThemeSettings.systemActiveID {
                    SettingsGridRow(title: "Light appearance") {
                        themePicker(
                            label: "Theme in the light appearance",
                            selection: model.systemLightThemeSelection
                        )
                        .accessibilityIdentifier("settings-system-light-theme-picker")
                    }

                    SettingsGridRow(title: "Dark appearance") {
                        themePicker(
                            label: "Theme in the dark appearance",
                            selection: model.systemDarkThemeSelection
                        )
                        .accessibilityIdentifier("settings-system-dark-theme-picker")
                    }
                }

                SettingsGridRow(title: "Interface font") {
                    fontFamilyPicker(
                        label: "Interface font family",
                        selection: model.interfaceFontFamilySelection,
                        options: interfaceFontFamilyOptions
                    )
                    .accessibilityIdentifier("settings-interface-font-picker")
                }

                SettingsGridRow(title: "Interface size") {
                    fontSizeStepper(
                        label: "Interface font size",
                        value: model.interfaceFontSizeSelection,
                        range: 9...28
                    )
                    .accessibilityIdentifier("settings-interface-size-stepper")
                }

                SettingsGridRow(title: "Editor font") {
                    fontFamilyPicker(
                        label: "Editor font family",
                        selection: model.editorFontFamilySelection,
                        options: editorFontFamilyOptions
                    )
                    .accessibilityIdentifier("settings-editor-font-picker")
                }

                SettingsGridRow(title: "Editor size") {
                    fontSizeStepper(
                        label: "Editor font size",
                        value: model.editorFontSizeSelection,
                        range: 9...28
                    )
                    .accessibilityIdentifier("settings-editor-size-stepper")
                }

                SettingsGridRow(title: "Terminal font") {
                    fontFamilyPicker(
                        label: "Terminal font family",
                        selection: model.terminalFontFamilySelection,
                        options: terminalFontFamilyOptions
                    )
                    .accessibilityIdentifier("settings-terminal-font-picker")
                }

                SettingsGridRow(title: "Terminal size") {
                    fontSizeStepper(
                        label: "Terminal font size",
                        value: model.terminalFontSizeSelection,
                        range: 8...32
                    )
                    .accessibilityIdentifier("settings-terminal-size-stepper")
                }

                SettingsGridRow(title: "Ligatures") {
                    Toggle(
                        "Enable font ligatures in the editor and terminals",
                        isOn: model.fontLigaturesSelection
                    )
                    .font(fonts.interfaceFont(sizeOffset: -1))
                    .foregroundStyle(themeUI(.controlForeground))
                    .tint(themeUI(.focusAccent))
                    .accessibilityLabel("Enable font ligatures")
                    .accessibilityIdentifier("settings-font-ligatures-toggle")
                }

                SettingsGridRow(title: "File browser font") {
                    fontFamilyPicker(
                        label: "File browser font family",
                        selection: model.fileBrowserFontFamilySelection,
                        options: fileBrowserFontFamilyOptions
                    )
                    .accessibilityIdentifier("settings-file-browser-font-picker")
                }

                if model.effectiveFonts.fileBrowserFamily != FontSettings.inheritFamily {
                    SettingsGridRow(title: "File browser size") {
                        fontSizeStepper(
                            label: "File browser font size",
                            value: model.fileBrowserFontSizeSelection,
                            range: 9...28
                        )
                        .accessibilityIdentifier("settings-file-browser-size-stepper")
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var installedFontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var interfaceFontFamilyOptions: [(String, String)] {
        fontFamilyOptions(pinned: [("system", "System")])
    }

    private var editorFontFamilyOptions: [(String, String)] {
        fontFamilyOptions(pinned: [("system-monospace", "System monospace")])
    }

    private var terminalFontFamilyOptions: [(String, String)] {
        fontFamilyOptions(
            pinned: [
                ("", "Ghostty default"),
                ("JetBrains Mono", "JetBrains Mono"),
                ("system-monospace", "System monospace"),
            ])
    }

    private var fileBrowserFontFamilyOptions: [(String, String)] {
        fontFamilyOptions(
            pinned: [
                (FontSettings.inheritFamily, "Inherit interface"),
                ("system", "System"),
                ("system-monospace", "System monospace"),
            ])
    }

    private func fontFamilyOptions(
        pinned: [(value: String, label: String)]
    ) -> [(String, String)] {
        let pinnedValues = Set(pinned.map(\.value))
        return pinned
            + installedFontFamilies
            .filter { !pinnedValues.contains($0) }
            .map { ($0, $0) }
    }

    private func themePicker(
        label: String,
        selection: Binding<String>
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(ThemeGroup.allCases) { group in
                Section(group.displayName) {
                    ForEach(ThemeCatalog.themes(in: group)) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                }
            }
        }
        .settingsMenuControl(maxWidth: 360)
        .accessibilityLabel(label)
    }

    private func fontFamilyPicker(
        label: String,
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .settingsMenuControl(maxWidth: 380)
        .accessibilityLabel(label)
    }

    private func fontSizeStepper(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        Stepper(value: value, in: range, step: 1) {
            Text("\(Int(value.wrappedValue.rounded())) pt")
                .font(fonts.interfaceFont(sizeOffset: -1))
                .foregroundStyle(themeUI(.controlForeground))
        }
        .foregroundStyle(themeUI(.controlForeground))
        .tint(themeUI(.focusAccent))
        .accessibilityLabel(label)
    }
}
