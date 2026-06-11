# Rewrite Deferred Issues Log

Running list of **minor** issues discovered during the rewrite that are
intentionally deferred to be addressed at completion (or as fast-follows). Only
minor items land here — every **major** issue must be addressed inline during
the chunk that surfaces it (per the owner's instruction).

Each entry: severity (minor/trivial), where it was found, what it is, and the
suggested fix.

| # | Severity | Area | Issue | Suggested fix |
|---|----------|------|-------|---------------|
| 1 | minor | `Theme/DraculaTheme.swift` | swiftlint warnings (not errors): `type_body_length` 385>250 and one `large_tuple` (3-member). File is ported verbatim for pixel-exact appearance parity. | Split `ThemeCatalog.themes` array into an `extension` in a sibling file; refactor the 3-tuple into a small struct. Both under the error threshold, so non-blocking. |
| 2 | minor | `Persistence/YAAWConfiguration.swift` (579), `KeyboardShortcutSettings.swift` (447) | `file_length` **warnings** (400<n<800). Cohesive type groups; under the 800 error ceiling. | Optional finer split (e.g. peel `KeyboardShortcutAction` out of the shortcuts file). Non-blocking. |
| 3 | minor | `Fonts/BundledFontCatalog.swift` (`performRegistration` 58 lines), `YAMLConfigurationStore.swift` (`render` 108 lines) | `function_body_length` **warnings** (50<n<120). `render` is one big verbatim template literal. | Extract the font-directory enumeration; leave `render` (a single template string) as-is. Non-blocking (under 120 error). |
