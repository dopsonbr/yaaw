# Agent Guidance

This repo contains a native macOS Agent IDE scaffold. Keep changes aligned with the documented hierarchy and requirements.

## Repo Rules

- Keep root files short and navigational.
- Put durable product docs under `docs/`.
- Put implementation plans under `docs/plans/`.
- Put requirements under `docs/requirements/` and use `MUST` / `SHOULD` language.
- Keep user-facing workflows under `docs/user-guide/`.
- Keep standards concise under `docs/standards/`.
- Do not write app metadata into user project directories.
- Preserve Apple Silicon/latest macOS scope unless requirements change.
- Preserve Dracula as the initial visual system.
- Prefer E2E behavior tests over internals tests.

## Implementation Bias

- Keep terminal, persistence, indexing, theme, and UI layout concerns separated.
- Use `libghostty` for embedded terminal surfaces.
- Keep right-panel state scoped to the selected thread.
- Treat `nvim` and `lazygit` as terminal-backed right-panel tools.
