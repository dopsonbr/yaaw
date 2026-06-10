# JetBrains Mono

YAAW bundles the JetBrains Mono typeface so the default editor and terminal font renders identically on every machine, including ligature support, without requiring a system-wide install.

- Version: 2.304
- Upstream: https://github.com/JetBrains/JetBrainsMono
- Release archive: https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
- License: SIL Open Font License 1.1 (OFL-1.1). The full license text ships alongside the font files at `src/Fonts/Resources/JetBrainsMono/OFL.txt` and is included in the app bundle.

The OFL permits bundling, redistribution, and commercial use as long as the fonts are not sold by themselves and the license text accompanies the font files. The fonts are registered at process scope only (`CTFontManagerRegisterFontsForURL` in `src/Fonts/BundledFontCatalog.swift`); nothing is installed to the user's system.

Bundled faces (static TTFs, kept intentionally small): Regular, Italic, Medium, SemiBold, Bold, BoldItalic.

## Re-vendoring

1. Download the release zip for the desired version from the upstream releases page.
2. Copy `fonts/ttf/JetBrainsMono-{Regular,Italic,Medium,SemiBold,Bold,BoldItalic}.ttf` and `OFL.txt` into `src/Fonts/Resources/JetBrainsMono/`.
3. Update the version and archive URL in this document.
