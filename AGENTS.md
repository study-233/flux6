# Flux6 repository guidance

This repository contains macOS, Android and Windows clients plus shared Go business code. iOS and OpenWrt are reserved platforms; do not implement them until requested.

- Use short-lived `feat/`, `fix/`, `refactor/`, `chore/` or `release/` branches. Do not use a `codex/` prefix or permanent platform development branches.
- Preserve existing application behavior during repository maintenance. Keep mechanical moves separate from behavior changes and removal commits.
- Keep signing keys, passwords and runtime configuration outside source control and outside disposable build caches.
- Read the platform's development instructions before changing it. Android's inherited rules apply within its project.
- Do not start real networking or stop user-owned processes for repository checks. Use unit tests, build checks and isolated fixtures.
- Keep shared Go changes covered by the affected platform checks, including nested Go modules.
- Preserve third-party licenses, source revisions and local patch records when moving or trimming vendored code.
- Record completed maintenance stages and verification limits in `docs/development/repository-maintenance.md`.
- Use Conventional Commits. Do not add agent co-author trailers.
