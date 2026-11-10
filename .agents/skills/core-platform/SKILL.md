---
name: core-platform
description: Use when changing Flux6 shared Go code, native bridges, service or process lifecycle, IPC contracts, Android VPN, macOS XPC, Windows helper, or platform build integration.
license: GPL-3.0; see ../../LICENSE and ../../UPSTREAM.md
---

# Core and platform

Read [AGENTS.md](../../../AGENTS.md), [platform boundaries](../../../docs/architecture/platforms.md) and the affected
platform guide. Paths below are repository-relative. Identify the actual owner and consumers before editing a bridge.

## Ownership and contracts

| Area | Authoritative boundary and references |
| --- | --- |
| Shared business | `cmd/`, `internal/`, `mobileapi/` and root `go.mod`; platform adapters consume existing Go business interfaces |
| macOS | Swift/AppKit host and XPC network service under `apps/macos/Sources/`, with Go worker business; [development](../../../apps/macos/DEVELOPMENT.md), [service v6](../../../shared/protocol/service-v6.md), [worker v1](../../../shared/protocol/worker-v1.md) |
| Android | Native `ServiceState` owns VPN intent; Dart/Core/Go integration stays in `apps/android`; [architecture](../../../apps/android/.agents/architecture.md), [lifecycle and Core rules](../../../apps/android/.agents/rules.md), [setting application](../../../apps/android/.agents/setting-changes.md) |
| Windows | Current Tauri or candidate native Flutter host talks to the existing `cmd/freev6-helper/` and shared Go; [migration boundaries](../../../docs/development/windows-flutter-refactor.md), [acceptance](../../../docs/development/windows-flutter-acceptance.md) |

Android's retained `lib/core/desktop/`, plugins and `services/helper/` support shared code and host tests. They are not
the Flux6 macOS XPC service or Windows Go helper. Retain them when referenced; do not restore removed upstream runners.

## Change safely at the owner

- Trace UI, background, notification, platform callback and exit paths that can reach the changed owner. Preserve
  latest-intent behavior under rapid start/stop/restart, stale responses, partial failure and repeated shutdown.
  Observation callbacks are not new user intent; successful stop must mean termination/restoration was confirmed.
- Keep process ownership and cleanup with the component that acquired the resource. Do not spawn a replacement while
  the previous owner is unresolved, broaden process-kill matching, or report cleanup complete before it is.
- Maintain bridge schemas across producers and consumers, including identifiers, error/timeout semantics, event ordering,
  bounded queues and cancellation. Prefer existing shared fixtures and protocol tests to duplicated assumptions.
- Follow Android's exact queue, gomobile error-return and `ServiceState` invariants when touching those paths. For
  setting changes, check whether the value applies live, re-applies a profile or requires a VPN restart.
- Preserve credential storage, IPC authentication, executable integrity and platform permission boundaries. Logs and
  test fixtures must not reveal real secrets. Use fake dependencies, temporary data and isolated fixtures for checks.
- Build hooks may invoke Go, Rust or native tools indirectly. Use the target platform's pinned toolchain and commands;
  do not disable hooks, relax checks or update vendor revisions merely to get a host test to run.

## Verification by affected consumer

- Shared Go, from the root: `go test -timeout=180s ./cmd/... ./internal/... ./mobileapi/...` and
  `go vet ./cmd/... ./internal/... ./mobileapi/...`. Avoid root `go test ./...`, which can traverse local SDK caches.
- Android Go, separately from `apps/android/core/`: `go test -timeout=180s ./...` and `go vet ./...`.
  Other affected nested modules also need their own checks; root tests do not cover them. Use Android's
  [commands](../../../apps/android/.agents/commands.md) for Dart protocol/lifecycle tests and Kotlin module checks.
- macOS: `bash scripts/macos/swift.sh test` plus affected Flutter/bridge tests and a build when native interfaces or
  packaging changed; use [development instructions](../../../apps/macos/DEVELOPMENT.md) to distinguish isolated tests from privileged probes.
- Windows: affected Web or Flutter checks plus Go/native host verification from its [guide](../../../apps/windows/README.md).
  Rust applies to the existing Tauri client, not the Flutter candidate. Native Windows permissions and installation require Windows.

Select affected consumers rather than assuming that a shared test covers every client. Do not run live networking or
install services as a routine check. Report unavailable toolchains and native acceptance gaps explicitly.
