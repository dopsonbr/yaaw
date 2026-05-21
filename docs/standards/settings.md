# Settings Standard

- Store user-editable app settings in app-owned YAML, not in user project directories.
- Default path is `~/Library/Application Support/YAAW/settings.yaml`; tests and local runs may override it with `YAAW_CONFIG_PATH`.
- Generate a commented YAML template when the file is missing.
- Keep comments focused on defaults and whether a setting is active now or reserved for future expansion.
- Parse settings forgivingly: unknown keys are ignored, missing keys use defaults, and malformed YAML recovers to defaults with a local diagnostic event.
- Theme settings should use stable built-in ids, default to `dracula`, and fall back to `dracula` with a local diagnostic event when unsupported.
- Font settings should use `system` / `system-monospace` for native macOS fonts, installed font family names for custom fonts, and bounded point sizes.
- Do not rewrite a user-edited settings file during normal load.
- Keep SQLite responsible for project, thread, layout, index, and session metadata.
