# Flux6 repository skills

The five skills in this directory serve macOS, Android, Windows and shared Go work. Their names have no platform
prefix. Android has no separate skill copies; its architecture, commands and coding references remain under
`apps/android/.agents/` and are loaded only for Android work.

Read [AGENTS.md](../AGENTS.md) first. Match the task to a skill's description, then read that skill and only the
references it needs. Paths written in skill prose are relative to the repository root unless a command specifies a
working directory; Markdown links are relative to their containing file.

| Skill | When to use |
| --- | --- |
| [localization](skills/localization/SKILL.md) | User-facing text, translations, ARB changes and generated locale output |
| [ui-work](skills/ui-work/SKILL.md) | Flutter or existing Windows Web UI, layout, components and interactions |
| [core-platform](skills/core-platform/SKILL.md) | Shared Go, native bridges, lifecycle, platform services and build integration |
| [ui-performance](skills/ui-performance/SKILL.md) | Dropped frames, slow interactions, excessive rebuilds, rendering or idle work |
| [pre-commit-quality-review](skills/pre-commit-quality-review/SKILL.md) | Commit/amend/squash preparation or an explicit structural review |

Keep each workflow here once. Update its platform references when ownership or build entry points change; technical
manuals stay in their platform directories and `docs/`. The skills grant no new authority for external actions.

These are repository-scoped skills, not global installations. No additional hook or editor configuration is required
by this change. [Upstream provenance and adaptation notes](UPSTREAM.md) retain the FlClash revision and license.
