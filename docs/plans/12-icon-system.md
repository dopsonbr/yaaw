# Plan 12: Icon System

## Summary

Add a native macOS icon system for the app shell, right-panel controls, file browser, Git state, diagnostics, and future icon-pack selection. The rule is: SF Symbols for behavior, Material/Catppuccin for file identity, and Codicons for VS Code inspiration only.

## Requirements

- Technical Requirements: Theme, Right Tool Panel, File Browser, External Tools, Global Navigation.
- Non-Functional Requirements: Usability, Accessibility, Performance, Packaging, Security And Privacy.
- Testing Requirements: Unit Test Policy, Screenshot Requirements, E2E Scope.
- Standards: SwiftUI Standard, AppKit Standard.

## Selected Icon Sources

- SF Symbols: app shell controls, toolbar actions, mode buttons, disclosure controls, diagnostics, settings, search, and navigation. Native symbols make the most sense when an icon represents an app command, navigation action, state, or macOS control.
- Material Icon Theme: default file-browser identity for languages, config files, folders, and common project files. It most closely matches VS Code's file-browser expectations while staying broad enough for mixed Swift, JavaScript, TypeScript, Markdown, shell, JSON, YAML, and Git repos.
- Catppuccin Icons: optional alternate file-browser pack for users who prefer a softer palette that sits closer to Dracula. It uses the same resolver boundary as Material Icon Theme.
- Codicons: product-icon reference only for VS Code-inspired concepts such as explorer, source control, search, split layout, terminal, collapse, and panel controls. Do not vendor Codicons unless the implementation also adds explicit license attribution.
- Octicons and Lucide remain fallback candidates for future gaps. Do not add either pack until a concrete app-owned use case is not covered well by SF Symbols.
- Avoid `vscode-icons` for the first version because its licensing and branded-icon surface create more review work than the app needs.

## Implementation

- Add an app-owned icon abstraction that separates semantic intent from rendering source:
  - `AppIcon` for system symbols and bundled assets.
  - `IconRole` for shell controls, panel mode controls, diagnostics, Git state, file kinds, folder kinds, and overlays.
  - `FileIconResolver` for file-browser paths.
- Keep SF Symbols as the default source for app UI roles:
  - Sidebar collapse and expand.
  - Right-panel mode buttons for Files, `nvim`, and Git.
  - Search, clear search, settings, project, thread, archive, pin, terminal, warning, error, and info states.
  - Disclosure, resize, refresh, and navigation controls where a native symbol exists.
- Add bundled file icon manifests behind a resolver instead of referencing SVG names directly from SwiftUI views.
- Implement VS Code-style file icon resolution order:
  - Exact file name, such as `Package.swift`, `package.json`, `Dockerfile`, `.gitignore`, `README.md`, and `AGENTS.md`.
  - Compound extension, such as `test.ts`, `spec.ts`, `d.ts`, `config.ts`, and `module.css`.
  - Extension, such as `swift`, `ts`, `tsx`, `js`, `json`, `md`, `yml`, `yaml`, `sh`, `sql`, `java`, `kt`, `py`, and `toml`.
  - Folder name, such as `src`, `docs`, `tests`, `.github`, `.vscode`, `node_modules`, `.build`, `dist`, and `assets`.
  - Directory open or closed state.
  - Generic file or folder fallback.
- Add file state overlays that can be resolved independently from base file icons:
  - Git modified, added, deleted, renamed, ignored, untracked, conflicted.
  - Indexing pending or failed.
  - External tool unavailable where relevant.
- Preserve Dracula as the app visual system:
  - Use original file-icon colors for recognition unless contrast fails on Dracula.
  - Use Dracula tokens for selection, hover, disabled, focus, and overlay states.
  - Keep inactive SF Symbols on the `comment` token and active controls on the appropriate Dracula accent.
- Add an icon-pack setting in the YAML settings schema with a default of `material-file-icons`.
  - Supported first values: `material-file-icons` and `catppuccin-file-icons`.
  - The setting controls only file and folder icons, not native app control icons.
  - Unknown values fall back to `material-file-icons` and log a non-sensitive diagnostic event.
- Add a small generated manifest for each bundled file icon pack:
  - Asset id.
  - Source pack.
  - Upstream license id.
  - Supported file names, extensions, folder names, and aliases.
  - Whether the icon is allowed in monochrome, full color, or both.
- Add third-party notice documentation for every vendored asset pack and keep upstream license files with the asset source snapshot.
- Keep source SVGs, source image assets, manifests, and generated app assets out of user project directories. Generated app assets remain inside the app bundle or repo-owned asset directory only.
- Avoid a custom image-processing runtime path in the app. Perform asset normalization at build time or as a checked-in generated asset step.

## Tests

- Unit tests for `FileIconResolver` exact-name precedence over extension matches.
- Unit tests for compound-extension precedence.
- Unit tests for folder-name and open-folder resolution.
- Unit tests for generic fallback behavior.
- Unit tests for unknown icon-pack settings falling back to Material Icon Theme.
- Unit tests for overlay composition that do not depend on Git command output.
- Snapshot or screenshot checks for the file browser on Dracula with:
  - Mixed language files.
  - Hidden files.
  - Selected, hovered, focused, and disabled rows.
  - Git modified, added, ignored, and conflicted overlays.
- Accessibility checks that icon-only controls expose meaningful labels.
- Packaging check verifies third-party notices and bundled asset manifests are present.

## Acceptance Criteria

- The right-panel mode controls use native macOS-style icons and expose accessibility labels.
- The file browser shows recognizable file and folder icons for common Swift, JavaScript, TypeScript, Markdown, JSON, YAML, shell, Git, and documentation files.
- `Package.swift`, `README.md`, `AGENTS.md`, `.gitignore`, `Dockerfile`, and `package.json` resolve through exact-file rules before extension rules.
- Material Icon Theme is the default file icon pack.
- Catppuccin Icons can be selected through app-owned YAML settings without changing app UI control icons.
- Unknown icon-pack setting values fall back to Material Icon Theme and emit a non-sensitive diagnostic event.
- File state overlays render independently from base file icons.
- Icon colors remain legible on Dracula selection, hover, focus, and inactive states.
- Bundled third-party asset packs include license notices.
- App metadata and generated icon assets are not written into user project directories.
- `scripts/build.sh` passes.
- `scripts/test.sh` passes with icon resolver coverage.
- `scripts/test-e2e.sh` passes or documents any environment-only blocker once Plan 10 exists.

## References

- [VS Code File Icon Theme Guide](https://code.visualstudio.com/api/extension-guides/file-icon-theme)
- [VS Code Product Icons](https://code.visualstudio.com/api/references/icons-in-labels)
- [SF Symbols](https://developer.apple.com/sf-symbols/)
- [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme)
- [Catppuccin Icons](https://github.com/catppuccin/vscode-icons)
- [Codicons](https://github.com/microsoft/vscode-codicons)
