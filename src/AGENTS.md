# Source Agent Guidance

- Keep UI, persistence, terminal, file indexing, and theme concerns separated.
- Keep `libghostty` terminal surfaces consistent across project, global, `nvim`, and `lazygit` terminals.
- Keep right-panel state scoped to the selected thread.
- Do not add a custom text editor for the MVP; use `nvim` in the right panel.
- Do not add a custom source control UI for the MVP; use `lazygit` in the right panel.
- Prefer public input/output behavior tests over private implementation tests.
