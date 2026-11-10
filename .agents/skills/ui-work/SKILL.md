---
name: ui-work
description: Use when changing Flux6 Flutter or existing Windows Web interfaces, including widgets, layout, styling, navigation, accessibility and asynchronous interactions.
license: GPL-3.0; see ../../LICENSE and ../../UPSTREAM.md
---

# UI work

Read [AGENTS.md](../../../AGENTS.md) and the target platform's UI guide. Paths below are repository-relative.

## Locate the client and its rules

| Client | UI and references |
| --- | --- |
| macOS | `apps/macos/flutter_ui/lib/`; [UI guide](../../../apps/macos/flutter_ui/README.md) and [component provenance](../../../apps/macos/flutter_ui/vendor/UPSTREAM.md) |
| Android | `apps/android/lib/`; [architecture](../../../apps/android/.agents/architecture.md), [rules](../../../apps/android/.agents/rules.md), [surface colors](../../../apps/android/.agents/surfaces.md) |
| Windows Flutter candidate | `apps/windows/flutter_ui/lib/`; [development](../../../apps/windows/flutter_ui/DEVELOPMENT.md) and [source/patch records](../../../apps/windows/flutter_ui/vendor/UPSTREAM.md) |
| Current Windows Web client | `apps/windows/web/`; [current client guide](../../../apps/windows/README.md) |

The Windows Flutter candidate does not replace the production Tauri entry point until its recorded acceptance step.
Match the request to the intended client before changing a screen.

## Implementation

- Reuse nearby widgets and state owners. Keep presentation in the UI and platform/network transitions in the existing
  host or service. Do not create another state-management layer or a cross-platform UI framework for a local change.
- Flutter surfaces use the pinned Prism UI package: `plugins/prism_ui` under Android and `vendor/prism_ui` under each
  desktop Flutter project. Reuse its shape and typography APIs, app glyphs and existing theme/surface roles. Read the
  actual pinned implementation before using an upstream API; preserve continuous corners where these components use them.
- Keep Android's `AppShape`/`AppRadius`, `AppTextStyle`, glyph, config-row, modal and navigation conventions in its
  technical references. Do not transplant Android providers or mobile navigation ownership into the Swift or Windows hosts.
- A generic component must not acquire app-state dependencies. Feature-specific orchestration stays with its feature;
  a vendor change needs its source and local-patch record updated. Similar desktop source copies are not permission
  to overwrite one platform from the other.
- Separate authoritative domain state, display-only progress/animation state, tap policy while busy, and cleanup.
  Release controllers, focus nodes, listeners and timers at their owner; handle failure and disposal as well as success.
  Clear transient progress in `finally` where applicable. Display smoothing must not hide a real error or change connection state.
- Preserve keyboard focus, semantic labels, tooltips, text scaling and pointer/touch behavior. Check narrow windows,
  safe areas, keyboard insets and one coherent scroll region for dialogs and sheets. Reuse route sizing rules rather
  than fixing a modal's dimensions at a call site.
- Use [localization](../localization/SKILL.md) for text changes. A loading, empty or failed state should follow that
  client's existing design; avoid introducing a different visual language for one screen.

## Verification

Use the project's dependency preparation, analyzer and affected tests. Android's existing `test/lint/` checks enforce
its widget conventions; cover the affected rules and widget paths. Add focused behavior regressions for meaningful
state/tap/error/cleanup changes, not tests that merely repeat a cosmetic constant.

Inspect relevant light/dark, narrow/wide, empty/loading/error and accessibility states using synthetic fixtures.
macOS and Windows have documented preview identities; a live client is not a UI test harness. Do not start networking,
replace an installed application or close a user-owned process for a screenshot.

For changes whose cost grows with data or animation, use [ui-performance](../ui-performance/SKILL.md). Report what
was visually inspected and distinguish widget/preview checks from native integration acceptance.
