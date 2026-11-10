# Flux6 Android agent guidance

Read the root `AGENTS.md` first. Current Android build and source information is in `FREEV6.md`; architecture, setting ownership and coding rules are in `.agents/architecture.md`, `.agents/setting-changes.md` and `.agents/rules.md`. `.agents/commands.md` contains current commands.

- Use `flutter test`, not `dart test`, and run `flutter pub get`, `flutter analyze --no-fatal-infos` plus affected suites before completing code changes.
- Do not edit generated models, providers, database or localization files manually; run the corresponding generators.
- Android lifecycle remains owned by ServiceState. UI code must not add a second source of lifecycle truth.
- Host tests still use shared desktop Core code and build hooks. Retain referenced support code even though desktop application runners have been removed.
- Preserve pinned upstream sources, licenses and local patch records. No Git submodule update or upstream release scripts apply to this source export.
- Use the five shared [repository skills](../../.agents/skills.md) for core/platform, UI, localization, performance and structural review. There are no Android-local skill copies; Android-specific technical references remain in this directory's `.agents/`.
- Use short-lived `feat/`, `fix/`, `refactor/`, `chore/` branches without a `codex/` prefix. Do not add agent co-author trailers.
- Never start real host networking or stop user-owned processes for checks; use isolated fixtures and recorded process IDs.
