---
name: ui-performance
description: Use when Flux6 interactions drop frames or feel slow, when reducing UI-thread, rendering or idle work, or when deciding whether data processing belongs in an isolate.
license: GPL-3.0; see ../../LICENSE and ../../UPSTREAM.md
---

# UI performance

Read [AGENTS.md](../../../AGENTS.md) and [ui-work](../ui-work/SKILL.md) for the affected client. For Android, also read
UI Frame Budget and UI Isolate Work in its [rules](../../../apps/android/.agents/rules.md), and the relevant rebuild,
page-arrival and background-work sections of its [architecture](../../../apps/android/.agents/architecture.md).

## Measurement workflow

1. Name the exact interaction and suspected cost: first visible frame, transition, scrolling, one-item update,
   resizing or idle polling. Record the build mode, dataset, display refresh rate, device and renderer.
2. Use deterministic synthetic data representing the expected upper bound. Choose sizes from the changed feature and
   existing fixtures: large node lists, log histories, rule sets or connection samples. Do not download a user's live
   configuration or launch the network core just to produce load.
3. Count rebuilds, paints, provider recomputations, database queries, event deliveries or render passes before timing.
   An update to one item should not trigger work proportional to every item without a demonstrated need.
4. Fix the cause in the affected layer: algorithmic complexity, repeated parsing/sorting, subscription scope, layout,
   retained rendering, timer lifetime or work triggered on every animation frame. Optimize or cache before introducing
   an isolate; account for serialization and result delivery as well as computation.
5. Compare base and change under the same conditions, alternating repeated runs to control drift. Validate output
   equivalence for algorithm changes and add a stable count/invariant regression where useful. Do not assert wall-clock
   durations in ordinary unit tests.
6. Keep a performance claim only when its improvement exceeds measurement noise and behavior stays equivalent.
   Report inconclusive experiments rather than accumulating unproven complexity.

Use a temporary worktree or a separate scratch harness for baseline comparisons; never overwrite the active source
with `git show`, use `git stash` on shared work, or leave a copied probe in tracked tests. Clean up only task-owned probes.

## Flutter probes and limits

- Rebuild/paint instrumentation and focused widget tests can expose excess work. Count initial builds separately from
  rebuilds and distinguish a composited repaint boundary from an actual paint.
- A provider observer may not report a recomputation that yields an equal value; a scoped counting override can expose
  it. Count database queries at the database boundary rather than inferring them from widget rebuilds.
- Pump animations frame by frame for bounded intervals; `pumpAndSettle` can hang with active progress indicators.
  Warm up JIT runs, and do not treat debug instrumentation overhead as production latency.
- Host `flutter test` is not a device frame-budget benchmark. Use an isolated profile harness for UI/raster timing,
  report refresh rate and distinguish CPU from GPU time. Android's existing 120 Hz budget applies within its documented
  rules; desktop and Web measurements need their actual target budget.
- Mac Apple Silicon raster timings alone do not establish GPU cost. Glass, blur and shader work may require a native
  GPU trace. For the Windows Web client use the existing browser rendering path, not Flutter counters.

## Safe platform measurements

macOS and Windows have documented synthetic preview entry points in their
[macOS](../../../apps/macos/flutter_ui/README.md) and [Windows](../../../apps/windows/flutter_ui/DEVELOPMENT.md) guides.
Verify the identity, data directory and disabled backend before launching a harness. Android profile/release installs
can replace the existing app; use an explicitly isolated test environment and the existing authorization, not the
user's installation. A performance request alone does not authorize installing a VPN or starting real networking.

Report base/change counts and timing summaries, dataset, repetitions, build mode, device/backend and uncertainty.
Distinguish host fixture results, emulator observations and measurements on the target hardware.
