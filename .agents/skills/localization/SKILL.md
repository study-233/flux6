---
name: localization
description: Use when changing Flux6 user-facing text or translations, scanning hardcoded UI strings, updating Android ARB files, or repairing generated locale output.
license: GPL-3.0; see ../../LICENSE and ../../UPSTREAM.md
---

# Localization

Read [AGENTS.md](../../../AGENTS.md) and the target platform's instructions. Paths below are repository-relative.
Use the existing text mechanism of the affected client; a copy edit is not permission to introduce a translation
framework across all clients. README translation is ordinary documentation work.

## Android

Read [Android rules](../../../apps/android/.agents/rules.md) for ARB accessors and dynamic message keys, and
[commands](../../../apps/android/.agents/commands.md) for environment preparation. Run these commands from `apps/android/`.

1. Scan the relevant UI sources and inspect nearby keys before adding one:

   ```bash
   rg -n '[\p{Han}]' lib -g '!l10n/**' -g '!**/generated/**'
   ```

2. Update the source files in `apps/android/arb/`. The existing locales are `en`, `zh_CN`, `ja`, `ru`, `fr`, `es` and
   `ko`; confirm the directory when adding a key so every supported locale and placeholder contract stays consistent.
   Preserve ARB metadata, interpolation names and plural semantics. Do not silently label untranslated text as translated.
3. In widgets use `context.appLocalizations` from `lib/common/context.dart`; outside widgets use
   `currentAppLocalizations` from `lib/common/app_localizations.dart`. Reuse the static enum-label switches in
   `lib/common/l10n_labels.dart` instead of composing `Intl.message` keys at runtime.
4. Regenerate and verify:

   ```bash
   dart run intl_utils:generate
   flutter analyze --no-fatal-infos
   flutter test test/l10n test/lint/dynamic_message_key_test.dart
   ```

5. Inspect the generated diff and repeat the targeted text scan. Fix missing or fallback values in ARB and regenerate;
   never manually patch `lib/l10n/`. Add affected widget checks if the text changes layout or interaction.

## macOS and Windows

The desktop Flutter projects currently have application text at their UI call sites and Prism component delegates in
`apps/macos/flutter_ui/lib/prism_localizations.dart` and `apps/windows/flutter_ui/lib/prism_localizations.dart`.
They do not use Android's ARB generator. Distinguish application labels, shared component labels, native-host messages
and the current Windows Web client before editing; keep protocol keys and error codes stable.

Update only the text owners the request touches. Preserve placeholders, access keys and accessibility labels; use
existing escaping for Web text. Changes to vendored Prism sources need the platform's source/patch records.
Validate long text, small windows and relevant locale/fallback states with existing fixtures, then run the affected
client's analyzer and tests from its [macOS](../../../apps/macos/flutter_ui/README.md) or
[Windows](../../../apps/windows/flutter_ui/DEVELOPMENT.md) guide. A desktop-wide multilingual rollout needs an explicit scope.

Report which clients/locales changed, whether generation ran, and any translation or visual checks left unverified.
