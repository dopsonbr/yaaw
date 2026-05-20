# E2E Testing Standard

- E2E tests are the primary confidence layer.
- Validate user-visible inputs and outputs.
- Include one full no-mock user journey through the app.
- Cover `codex` and `claude` thread creation, session naming, and session resume with deterministic CLI fixtures or command doubles.
- Capture screenshots for failures and key UI states.
- Do not replace behavior assertions with screenshots alone.
