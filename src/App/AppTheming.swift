import AppKit
import SwiftUI
import YAAWKit

/// Theme-token color resolved from the `appTheme` environment. Mirrors the
/// pre-rewrite `dracula(_:)`/`themeUI(_:)` helpers so view bodies look up the
/// active theme's colors lazily; a theme change invalidates the views that read
/// them.
func dracula(_ role: ThemeRole) -> AppThemeColor {
    AppThemeColor(role: role)
}

func themeUI(_ role: ThemeUIRole) -> AppThemeUIColor {
    AppThemeUIColor(role: role)
}

struct AppThemeColor: ShapeStyle {
    let role: ThemeRole

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(hex: environment.appTheme.hex(for: role)).resolve(in: environment)
    }
}

struct AppThemeUIColor: ShapeStyle {
    let role: ThemeUIRole

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(hex: environment.appTheme.uiHex(for: role)).resolve(in: environment)
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeCatalog.defaultTheme
}

private struct FontSettingsEnvironmentKey: EnvironmentKey {
    static let defaultValue = FontSettings()
}

extension EnvironmentValues {
    var appTheme: ThemeDefinition {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }

    var fontSettings: FontSettings {
        get { self[FontSettingsEnvironmentKey.self] }
        set { self[FontSettingsEnvironmentKey.self] = newValue }
    }
}

extension ThemeDefinition {
    var swiftUIColorScheme: ColorScheme {
        switch preferredColorScheme {
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

extension FontSettings {
    func interfaceFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        swiftUIFont(
            family: interfaceFamily, size: interfaceSize + sizeOffset, weight: weight,
            design: .default)
    }

    func editorFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        swiftUIFont(
            family: editorFamily, size: editorSize + sizeOffset, weight: weight,
            design: .monospaced, ligatures: ligatures
        )
    }

    /// File browser list font. When `fileBrowserFamily` is `inherit` (the
    /// default), resolves to the interface font/size so it matches the chrome.
    func fileBrowserFont(sizeOffset: Double = 0, weight: Font.Weight = .regular) -> Font {
        let normalized = fileBrowserFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let inherits = normalized.isEmpty || normalized == FontSettings.inheritFamily
        let family = inherits ? interfaceFamily : fileBrowserFamily
        let baseSize = fileBrowserSize > 0 ? fileBrowserSize : interfaceSize
        return swiftUIFont(
            family: family, size: baseSize + sizeOffset, weight: weight, design: .default)
    }

    private func swiftUIFont(
        family: String,
        size: Double,
        weight: Font.Weight,
        design: Font.Design,
        ligatures: Bool = true
    ) -> Font {
        let pointSize = CGFloat(max(6, size))
        switch family.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "system":
            return .system(size: pointSize, weight: weight, design: .default)
        case "system-monospace", "monospace":
            return .system(size: pointSize, weight: weight, design: .monospaced)
        default:
            if !ligatures,
                let font = ligatureFreeFont(family: family, size: pointSize, weight: weight)
            {
                return font
            }
            return .custom(family, size: pointSize).weight(weight)
        }
    }

    /// CoreText shapes a font's default ligatures automatically, so turning them
    /// off requires an AppKit descriptor that zeroes the OpenType features.
    private func ligatureFreeFont(family: String, size: CGFloat, weight: Font.Weight) -> Font? {
        let features: [[NSFontDescriptor.FeatureKey: Any]] = ["calt", "liga", "dlig", "clig"].map {
            [
                .init(rawValue: kCTFontOpenTypeFeatureTag as String): $0,
                .init(rawValue: kCTFontOpenTypeFeatureValue as String): 0,
            ]
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .featureSettings: features,
            .traits: [NSFontDescriptor.TraitKey.weight: nsFontWeight(for: weight).rawValue],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size) else { return nil }
        return Font(font)
    }

    private func nsFontWeight(for weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255.0,
            green: Double((rgb >> 8) & 0xff) / 255.0,
            blue: Double(rgb & 0xff) / 255.0
        )
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255.0,
            green: CGFloat((rgb >> 8) & 0xff) / 255.0,
            blue: CGFloat(rgb & 0xff) / 255.0,
            alpha: 1
        )
    }
}
