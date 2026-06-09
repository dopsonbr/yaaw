import AppKit
import GhosttyTerminal
import SwiftUI
import YAAWKit

public struct TerminalHostRenderingConfiguration {
    public let terminalTheme: TerminalTheme
    public let terminalConfiguration: TerminalConfiguration
    public let appKitAppearanceName: NSAppearance.Name
    public let swiftUIColorScheme: ColorScheme

    /// Resolves a rendering payload into concrete configuration, centralizing
    /// the theme-catalog and font-size fallbacks.
    public static func make(
        for rendering: IsolatedTerminalRendering
    ) -> TerminalHostRenderingConfiguration {
        make(
            for: rendering.themeID.flatMap(ThemeCatalog.theme(id:)) ?? ThemeCatalog.defaultTheme,
            fontSize: Float(rendering.terminalFontSize ?? FontSettings().terminalSize),
            fontFamily: rendering.terminalFontFamily
        )
    }

    public static func make(
        for theme: ThemeDefinition,
        fontSize: Float,
        fontFamily: String?
    ) -> TerminalHostRenderingConfiguration {
        let terminalThemeConfiguration = Self.terminalThemeConfiguration(for: theme)
        var terminalConfiguration = Self.nonThemeTerminalConfiguration(fontSize: fontSize)
        if let family = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
            !family.isEmpty
        {
            terminalConfiguration = terminalConfiguration.fontFamily(family)
        }

        return TerminalHostRenderingConfiguration(
            terminalTheme: TerminalTheme(
                light: terminalThemeConfiguration,
                dark: terminalThemeConfiguration
            ),
            terminalConfiguration: terminalConfiguration,
            appKitAppearanceName: appKitAppearanceName(for: theme.preferredColorScheme),
            swiftUIColorScheme: swiftUIColorScheme(for: theme.preferredColorScheme)
        )
    }

    static func terminalThemeConfiguration(for theme: ThemeDefinition) -> TerminalConfiguration {
        TerminalConfiguration { config in
            config.withBackground(themeHex(.background, in: theme))
            config.withForeground(themeHex(.foreground, in: theme))
            config.withSelectionBackground(themeHex(.currentLine, in: theme))
            config.withSelectionForeground(themeHex(.foreground, in: theme))
            config.withCursorColor(themeHex(.pink, in: theme))
            config.withCursorText(themeHex(.background, in: theme))
            config.withBoldColor(themeHex(.yellow, in: theme))
            for (index, color) in theme.terminalANSIPalette.enumerated() {
                config.withPalette(index, color: color)
            }
        }
    }

    static func nonThemeTerminalConfiguration(fontSize: Float) -> TerminalConfiguration {
        TerminalConfiguration { config in
            config.withFontSize(fontSize)
            config.withWindowPaddingX(0)
            config.withWindowPaddingY(0)
        }
    }

    static func appKitAppearanceName(
        for colorScheme: ThemePreferredColorScheme
    ) -> NSAppearance.Name {
        switch colorScheme {
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }

    static func swiftUIColorScheme(for colorScheme: ThemePreferredColorScheme) -> ColorScheme {
        switch colorScheme {
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private static func themeHex(_ role: ThemeRole, in theme: ThemeDefinition) -> String {
        theme.hex(for: role).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }
}
