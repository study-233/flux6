# Android commands

Run from the repository root:

```bash
source scripts/android/env.sh
bash scripts/android/build-apk.sh
python3 scripts/android/package-source.py
```

From `apps/android/`, use `flutter pub get`, `flutter analyze --no-fatal-infos` and `flutter test` with the suites covering the change. Use `flutter test`, not `dart test`. `tool/test.dart` runs the retained broader suite. Build hooks require Go and may require Rust; do not disable them in committed configuration. The Android core is compiled by Gradle through gomobile.

From `apps/android/core/`, run `go test ./...` and `go vet ./...`. From `apps/android/android/`, run `./gradlew :app:testDebugUnitTest :service:testDebugUnitTest -Ptarget-platform=android-arm64` with the configured JDK and SDK.

After models, providers or database schema changes run `dart run build_runner build --delete-conflicting-outputs`. After ARB changes run `dart run intl_utils:generate`. Do not edit generated Dart files by hand.

No Git submodules or upstream `setup.dart` release pipeline are used. Sources are pinned and recorded in `FREEV6.md`. The root workflows own CI and release checks.

Do not run the client with real host networking for a repository check. Use tests or an explicitly isolated safe-mode build. Stop only processes started for the task, by recorded PID.
