# Agent guidance provenance

Adapted on 2026-11-10 from [chen08209/FlClash](https://github.com/chen08209/FlClash), revision
[`be84736605527034689c95bf27828ff27d912c5e`](https://github.com/chen08209/FlClash/commit/be84736605527034689c95bf27828ff27d912c5e)
(v0.9.3). Upstream authors retain attribution. These are modified Flux6 instructions, not an unmodified upstream export.

| Upstream file at the pinned revision | Flux6 destination |
| --- | --- |
| [AGENTS.md](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/AGENTS.md) | [Root agent instructions](../AGENTS.md) |
| [.agents/skills/localization/SKILL.md](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/.agents/skills/localization/SKILL.md) | [localization](skills/localization/SKILL.md) |
| [.agents/skills/ui-work/SKILL.md](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/.agents/skills/ui-work/SKILL.md) | [ui-work](skills/ui-work/SKILL.md) |
| [.agents/skills/core-platform/SKILL.md](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/.agents/skills/core-platform/SKILL.md) | [core-platform](skills/core-platform/SKILL.md) |
| [.agents/skills/ui-performance/SKILL.md](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/.agents/skills/ui-performance/SKILL.md) | [ui-performance](skills/ui-performance/SKILL.md) |
| [.agents/skills/pre-commit-quality-review/SKILL.md](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/.agents/skills/pre-commit-quality-review/SKILL.md) | [pre-commit-quality-review](skills/pre-commit-quality-review/SKILL.md) |

## License

The FlClash-derived additions to root `AGENTS.md` and the five `SKILL.md` files retain the upstream GPL-3.0 license;
the unmodified license text is in [LICENSE](LICENSE). Existing Flux6 material retains its existing license. This
provenance entry does not relicense the application or any third-party component.

## Local adaptations

- Merged upstream navigation and workflow principles with Flux6's existing branch, platform, signing and network constraints.
- Replaced upstream desktop lifecycle and Helper paths with Flux6's Swift/XPC and Windows Go-helper boundaries.
- Made localization platform-aware: Android retains ARB generation; desktop text follows its existing call sites and Prism delegates.
- Retained component reuse, asynchronous-state separation and measurement-driven performance work, with isolated fixtures
  and budgets appropriate to the actual display instead of a phone-only global threshold.
- Kept review scoped to introduced structural problems and existing authorization; no redundant approval gate for an
  already-authorized in-scope fix, and no claim that upstream hooks are installed.
- Consolidated the five Android skill copies into the root without prefixes. Android technical references remain in
  [apps/android/.agents](../apps/android/.agents); source-package and product build scripts are unchanged.
- Added no upstream editor hooks, subagent configuration, release automation or global skill installation.

For a future sync, compare against this exact revision, retain local platform boundaries and update these notes.
