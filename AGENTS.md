# Flux6 repository guidance

This repository contains macOS, Android and Windows clients plus shared Go business code. iOS and OpenWrt are reserved platforms; do not implement them until requested.

## Start here

Read the [development guide](docs/development/README.md) for repository layout, branches, signing and checks, and the
[platform boundaries](docs/architecture/platforms.md) before changing shared responsibilities. Read the relevant
platform instructions before editing that platform:

| Area | Instructions |
| --- | --- |
| macOS | [Build and distribution](apps/macos/README.md), [development and service verification](apps/macos/DEVELOPMENT.md), [Flutter UI](apps/macos/flutter_ui/README.md) |
| Android | [Android AGENTS.md](apps/android/AGENTS.md), [Flux6 build and sources](apps/android/FREEV6.md), [commands](apps/android/.agents/commands.md); inherited Android rules apply within that project |
| Windows | [Current client](apps/windows/README.md), [Flutter development](apps/windows/flutter_ui/DEVELOPMENT.md), [migration acceptance](docs/development/windows-flutter-acceptance.md) |
| Shared Go and protocols | [Platform boundaries](docs/architecture/platforms.md), the affected contract in [shared/protocol](shared/protocol), and each consuming platform's instructions |

Use the matching [repository skill](.agents/skills.md); load only the skill and references relevant to the task.

## Scope and workflow

- Implement explicit, bounded, low-risk requests after reading the relevant context. Ask only when material ambiguity,
  destructive impact, missing authority or a scope change would alter the result; do not add a planning or approval ritual.
- Keep edits scoped to the requested outcome. Report unrelated historical issues separately. Prefer a targeted edit
  over rewriting a file, and preserve unrelated changes and partial staging.
- Use short-lived `feat/`, `fix/`, `refactor/`, `chore/` or `release/` branches. Do not use a `codex/` prefix or permanent platform development branches.
- Preserve existing application behavior during repository maintenance. Keep mechanical moves separate from behavior changes and removal commits.
- Use an isolated worktree when another task owns the current checkout. Do not switch its branch, stash its work or
  overwrite its files to compare versions. Keep temporary probes and outputs outside tracked source.
- Use Conventional Commits. Do not add agent co-author trailers. A review does not itself authorize a push, release or history rewrite.

## Implementation boundaries

- Keep one authoritative owner for lifecycle and platform effects: macOS uses its Swift/AppKit host and XPC service,
  Android uses `ServiceState`, and Windows uses its host and existing Go helper. UI state and callbacks must not
  become a second lifecycle controller. Check rapid start/stop/restart, stale completion and exit paths when changing them.
- Shared Go business code stays under its current module boundaries. A portable test passing does not prove each
  platform integration works; nested Android Go modules require their own checks.
- Preserve the current platform UI and reuse its components, shape, typography and color tokens. Android-specific
  widgets, providers and rules are not automatically the architecture of the desktop clients.
- Follow the target project's lint and generated-code rules. Update source models, providers, schemas or ARB files
  and run their generators; do not patch generated output by hand.
- Comments should explain a non-obvious constraint or reason that code cannot express. Avoid narrating changes or
  restating statements; retain license headers, tool directives and upstream notices. Do not infer a repository-wide
  comment-density gate from an upstream hook that is not installed here.

## Runtime, sources and secrets

- Keep signing keys, passwords and runtime configuration outside source control and outside disposable build caches.
- Do not start real networking or stop user-owned processes for repository checks. Use unit tests, build checks and isolated fixtures.
- A UI preview must use its documented isolated identity and synthetic data. End only processes started for this
  task, by recorded PID; never stop an application by name or replace the user's installed application for a check.
- Preserve third-party licenses, source revisions and local patch records when moving or trimming vendored code.
  The Android export and desktop UI components are pinned sources, not a request to run upstream submodule or release workflows.

## Verification and reporting

- Select checks by the files and responsibilities changed, using the [development guide](docs/development/README.md)
  and platform instructions. Shared Go changes need affected platform checks, including nested Go modules.
- Flutter code changes require the project's dependency preparation, analyzer and affected `flutter test` suites;
  use `flutter test` rather than `dart test` for Flutter-dependent code. Reuse valid results and repeat checks when
  later edits invalidate them. Documentation-only changes need link, skill and repository checks rather than application builds.
- Add focused regressions for changed behavior where needed. Do not add tests that only mirror implementation or
  require real networking for a routine repository check.
- State what was checked, what failed or was skipped, and why. Distinguish portable tests and previews from native
  build, signing, permission, installation and real-network acceptance.
- Record completed maintenance stages and verification limits in [repository-maintenance.md](docs/development/repository-maintenance.md).

The agent-guidance additions and skills adapt FlClash's practices; [source revision, license and local adaptations](.agents/UPSTREAM.md) are recorded separately.
