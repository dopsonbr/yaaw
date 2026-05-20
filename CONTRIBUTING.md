# Contributing

## Workflow

1. Read `README.md` and `docs/README.md` first.
2. Check applicable requirements in `docs/requirements/`.
3. Add or update an implementation plan under `docs/plans/` before large changes.
4. Keep public docs, requirements, and tests aligned with behavior changes.

## Testing Expectations

- Prefer E2E tests that validate user-visible behavior.
- Capture screenshots for E2E failures and key UI states.
- Unit tests are allowed when they validate high-value public input/output behavior.
- Do not test private functions or framework internals directly.

## Documentation Expectations

- Requirements use `MUST`, `SHOULD`, and `MAY` language.
- User docs describe workflows, not implementation internals.
- Standards should be concise and enforceable.
