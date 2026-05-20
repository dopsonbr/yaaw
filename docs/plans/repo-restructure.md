# Repo Restructure Proposal

This proposal defines a repo layout for the native macOS Agent IDE. It keeps the root small, moves durable product documentation under `docs/`, and separates app source, scripts, standards, requirements, and agent guidance.

## Goals

- Keep the root readable for new contributors.
- Make the documentation hierarchy explicit.
- Keep requirements separate from implementation plans.
- Give agents local instructions at the root, docs, and source levels.
- Leave room for native macOS source conventions without forcing a final Swift package layout too early.
- Keep generated examples and screenshots discoverable.

## Proposed Tree

```text
.
├── .agents/
│   ├── skills/
│   └── workflows/
├── scripts/
│   ├── bootstrap.sh
│   ├── test-e2e.sh
│   ├── test-unit.sh
│   └── format.sh
├── docs/
│   ├── AGENTS.md
│   ├── README.md
│   ├── user-guide/
│   │   └── README.md
│   ├── requirements/
│   │   ├── technical-requirements.md
│   │   ├── non-functional-requirements.md
│   │   └── testing-requirements.md
│   ├── plans/
│   │   └── repo-restructure.md
│   ├── standards/
│   │   ├── lang/
│   │   │   └── swift.md
│   │   ├── framework/
│   │   │   ├── swiftui.md
│   │   │   └── appkit.md
│   │   ├── dependency/
│   │   │   ├── libghostty.md
│   │   │   ├── sqlite.md
│   │   │   ├── nvim.md
│   │   │   └── lazygit.md
│   │   └── testing/
│   │       └── e2e.md
│   ├── design/
│   │   └── README.md
│   └── examples/
│       └── screenshots/
├── src/
│   ├── AGENTS.md
│   ├── App/
│   ├── Core/
│   ├── Terminal/
│   ├── Projects/
│   ├── Threads/
│   ├── FileBrowser/
│   ├── RightPanel/
│   ├── Persistence/
│   ├── Theme/
│   └── Tests/
├── AGENTS.md
├── README.md
├── QUICKSTART.md
└── CONTRIBUTING.md
```

## Root Files

| Path | Purpose |
| --- | --- |
| `README.md` | Project overview, doc hierarchy, screenshots, and links. |
| `QUICKSTART.md` | Minimal local setup and first run path. |
| `CONTRIBUTING.md` | Contribution workflow, test expectations, and PR standards. |
| `AGENTS.md` | Root guidance for agents working anywhere in the repo. |

The root should not hold long-form requirements or plans. Those belong under `docs/`.

## Documentation Layout

### `docs/README.md`

Acts as the documentation landing page. It should mirror the hierarchy:

1. Root `README.md`
2. `docs/user-guide/README.md`
3. `docs/requirements/`
4. `docs/plans/`
5. `docs/design/`
6. `docs/standards/`

### `docs/user-guide/`

Contains user-facing workflow documentation.

Current migration:

- `USER_GUIDE.md` -> `docs/user-guide/README.md`

### `docs/requirements/`

Contains product and quality requirements. These should use `MUST` / `SHOULD` language and avoid implementation plans.

Current migration:

- `TECHNICAL_REQUIREMENTS.md` -> `docs/requirements/technical-requirements.md`
- `NON_FUNCTIONAL_REQUIREMENTS.md` -> `docs/requirements/non-functional-requirements.md`
- `TESTING_REQUIREMENTS.md` -> `docs/requirements/testing-requirements.md`

### `docs/design/`

Contains durable design and architecture docs.

Current migration:

- `DESIGN.md` -> `docs/design/README.md`

### `docs/plans/`

Contains implementation plans and migration proposals. Plans should be written after requirements and should reference the relevant requirement sections.

The current file belongs here:

- `docs/plans/repo-restructure.md`

### `docs/standards/`

Contains specific engineering standards.

Recommended categories:

- `docs/standards/lang/`
- `docs/standards/framework/`
- `docs/standards/dependency/`
- `docs/standards/testing/`

Standards should be short and enforceable. They should not duplicate full requirements docs.

### `docs/examples/screenshots/`

Stores generated example screenshots.

Current migration:

- `examples/*.png` -> `docs/examples/screenshots/*.png`

## Source Layout

The `src/` directory is acceptable for this app even though many native macOS projects use the app target name as the top-level source directory. Using `src/` keeps the repo easy to scan while the app structure is still forming.

Recommended source modules:

| Path | Responsibility |
| --- | --- |
| `src/App/` | App entry point, scene setup, window coordination. |
| `src/Core/` | Shared models, command routing, app-level services. |
| `src/Terminal/` | `libghostty` embedding, terminal lifecycle, PTY/session coordination. |
| `src/Projects/` | Project creation, selection, metadata, global project behavior. |
| `src/Threads/` | Thread creation, worktree association, archive behavior. |
| `src/FileBrowser/` | File tree, hidden files, fuzzy matching, ignore rules. |
| `src/RightPanel/` | Files / `nvim` / `lazygit` mode switching and state. |
| `src/Persistence/` | SQLite schema, migrations, repositories, JSON config. |
| `src/Theme/` | Dracula tokens and shared visual system. |
| `src/Tests/` | Test fixtures and test utilities if the native test target needs shared helpers. |

If the eventual Xcode project or Swift package prefers app-target naming, `src/` can still contain the implementation and be referenced by the project file.

## Agent Guidance Files

### Root `AGENTS.md`

Should define repo-wide behavior:

- Do not move product docs out of `docs/`.
- Keep root files short and navigational.
- Prefer E2E behavior tests over internals tests.
- Do not write metadata into user project directories.
- Use Dracula tokens.
- Keep app Apple Silicon/latest macOS only unless requirements change.

### `docs/AGENTS.md`

Should define documentation behavior:

- Preserve the hierarchy.
- Requirements use `MUST` / `SHOULD` language.
- Plans reference requirement sections.
- User docs describe workflows, not implementation internals.
- Standards stay concise and enforceable.

### `src/AGENTS.md`

Should define source behavior:

- Keep UI, persistence, terminal, and indexing concerns separated.
- Do not test private functions directly.
- Use public input/output behavior for unit tests.
- Keep `libghostty` terminal surfaces consistent across project, global, `nvim`, and `lazygit` terminals.
- Keep right-panel state scoped to thread.

## Migration Plan

1. Create the target directories.
2. Move user guide, requirements, testing, and design docs under `docs/`.
3. Move screenshots from `examples/` to `docs/examples/screenshots/`.
4. Add root `QUICKSTART.md`, `CONTRIBUTING.md`, and `AGENTS.md`.
5. Add `docs/README.md`, `docs/AGENTS.md`, and `src/AGENTS.md`.
6. Add placeholder standards under `docs/standards/`.
7. Update links in `README.md` and docs.
8. Add scripts once the build/test toolchain exists.

## Recommended First Commit Shape

The first restructure commit should be docs-only and should not introduce source files beyond empty directory placeholders or `AGENTS.md` guidance files.

Recommended first commit contents:

- Root `README.md`, `QUICKSTART.md`, `CONTRIBUTING.md`, `AGENTS.md`.
- `docs/README.md`.
- `docs/user-guide/README.md`.
- `docs/requirements/*.md`.
- `docs/design/README.md`.
- `docs/plans/repo-restructure.md`.
- `docs/standards/**`.
- `docs/examples/screenshots/*.png`.
- `src/AGENTS.md`.
- `scripts/README.md` or initial placeholder scripts.
