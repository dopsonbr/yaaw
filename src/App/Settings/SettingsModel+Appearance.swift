import SwiftUI
import YAAWKit

extension SettingsModel {
    // MARK: - Appearance: theme

    var themeSelection: Binding<String> {
        Binding(
            get: { self.selectedThemeID },
            set: { newValue in
                guard self.selectedThemeID != newValue else { return }
                self.selectedThemeID = newValue
                self.saveThemeSelection(newValue)
            }
        )
    }

    private func saveThemeSelection(_ themeID: String) {
        do {
            var nextConfiguration = try dependencies.validateText(editorText)
            nextConfiguration.theme.active = themeID
            let renderedText = YAMLConfigurationStore.render(nextConfiguration)
            _ = try dependencies.saveText(renderedText)
            editorText = renderedText
            lastSavedText = renderedText
            currentConfiguration = nextConfiguration.validated()
            selectedThemeID = themeID
            globalChatsDirectoryText = currentConfiguration.projects.globalChatsDirectory
            syncAgentLaunchTextFields(with: currentConfiguration)
            validationError = nil
            statusMessage = "Theme saved and applied."
        } catch {
            selectedThemeID = currentConfiguration.themeName
            validationError = "YAML validation failed: \(error)"
            statusMessage = "Theme was not changed."
        }
    }

    var systemLightThemeSelection: Binding<String> {
        Binding(
            get: { self.currentConfiguration.theme.light },
            set: { newValue in
                self.saveConfigurationMutation(
                    successStatus: "Theme saved and applied.",
                    failureStatus: "Theme was not changed."
                ) { $0.theme.light = newValue }
            }
        )
    }

    var systemDarkThemeSelection: Binding<String> {
        Binding(
            get: { self.currentConfiguration.theme.dark },
            set: { newValue in
                self.saveConfigurationMutation(
                    successStatus: "Theme saved and applied.",
                    failureStatus: "Theme was not changed."
                ) { $0.theme.dark = newValue }
            }
        )
    }

    // MARK: - Appearance: fonts

    func saveFontSettings(_ mutate: @escaping (inout FontSettings) -> Void) {
        saveConfigurationMutation(
            successStatus: "Font settings saved and applied.",
            failureStatus: "Font settings were not changed."
        ) {
            mutate(&$0.fonts)
        }
    }

    var interfaceFontFamilySelection: Binding<String> {
        Binding(
            get: { self.effectiveFonts.interfaceFamily },
            set: { newValue in self.saveFontSettings { $0.interfaceFamily = newValue } }
        )
    }

    var interfaceFontSizeSelection: Binding<Double> {
        Binding(
            get: { self.effectiveFonts.interfaceSize },
            set: { newValue in self.saveFontSettings { $0.interfaceSize = newValue } }
        )
    }

    var editorFontFamilySelection: Binding<String> {
        Binding(
            get: { self.effectiveFonts.editorFamily },
            set: { newValue in self.saveFontSettings { $0.editorFamily = newValue } }
        )
    }

    var editorFontSizeSelection: Binding<Double> {
        Binding(
            get: { self.effectiveFonts.editorSize },
            set: { newValue in self.saveFontSettings { $0.editorSize = newValue } }
        )
    }

    var terminalFontFamilySelection: Binding<String> {
        Binding(
            get: { self.effectiveFonts.terminalFamily },
            set: { newValue in self.saveFontSettings { $0.terminalFamily = newValue } }
        )
    }

    var terminalFontSizeSelection: Binding<Double> {
        Binding(
            get: { self.effectiveFonts.terminalSize },
            set: { newValue in self.saveFontSettings { $0.terminalSize = newValue } }
        )
    }

    var fontLigaturesSelection: Binding<Bool> {
        Binding(
            get: { self.effectiveFonts.ligatures },
            set: { newValue in self.saveFontSettings { $0.ligatures = newValue } }
        )
    }

    var fileBrowserFontFamilySelection: Binding<String> {
        Binding(
            get: { self.effectiveFonts.fileBrowserFamily },
            set: { newValue in self.saveFontSettings { $0.fileBrowserFamily = newValue } }
        )
    }

    var fileBrowserFontSizeSelection: Binding<Double> {
        Binding(
            get: {
                self.effectiveFonts.fileBrowserSize > 0
                    ? self.effectiveFonts.fileBrowserSize : self.effectiveFonts.interfaceSize
            },
            set: { newValue in self.saveFontSettings { $0.fileBrowserSize = newValue } }
        )
    }
}
