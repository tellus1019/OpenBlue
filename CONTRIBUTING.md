# Contributing to OpenBlue

Thank you for contributing to OpenBlue.

OpenBlue is intentionally focused on the original Blue Yeti running on Apple Silicon macOS.
Changes should support that scope and prioritize reliability, predictable behavior, low latency, privacy, and maintainability.

## Workflow

1. Create a short-lived branch from `main`.
2. Keep each pull request limited to one logical change.
3. Add or update meaningful tests when behavior changes.
4. Run the relevant build and test commands before requesting review.
5. Submit the change through a pull request.

Use one of these branch prefixes when applicable:

- `feat/`
- `fix/`
- `test/`
- `docs/`
- `chore/`

## Language

Use English for source comments, documentation, issue content, pull request content, commit messages, and other repository-facing text.

Comments should explain intent, constraints, or non-obvious behavior rather than restating the code.

## Pull Requests

Write pull request titles using this format:

```text
type: concise imperative summary
```

The supported types are:

- `feat`
- `fix`
- `docs`
- `test`
- `build`
- `ci`
- `chore`

Include a summary, testing evidence, and relevant risks in every pull request.

OpenBlue uses squash merges, so the pull request title becomes the commit message on `main`.

## Testing

Tests should provide confidence in observable behavior rather than duplicate implementation logic.

Audio processing changes should use controlled signals or redistributable fixtures and should cover parameter limits, bypass behavior, and failure cases when applicable.

Do not commit private microphone recordings, conversations, credentials, signing material, proprietary samples, or other sensitive data.

## License

By submitting a contribution, you agree that it is licensed under the Apache License 2.0 used by this repository.
