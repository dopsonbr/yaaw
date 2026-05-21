# Documentation Agent Guidance

- Preserve the documentation hierarchy from `docs/README.md`.
- Keep root docs navigational and move long-form content under `docs/`.
- Requirements belong under `docs/requirements/` and use `MUST` / `SHOULD` language.
- Plans belong under `docs/plans/` and should reference applicable requirement sections.
- User guide content should describe user workflows, not implementation internals.
- Standards should be short, specific, and enforceable.
- Keep screenshot references pointed at `docs/examples/screenshots/`.
- Keep GitHub Pages presentation files under `docs/site/`; do not move durable product content there.
- `docs/site/` should contain only the Pages shell: layouts, CSS, config, and homepage content.
- The Pages workflow stages Markdown docs with the `docs/site/` shell. Treat `.pages/` and `_site/` as ignored local build output.
