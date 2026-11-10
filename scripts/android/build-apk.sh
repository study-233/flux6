#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$FREEV6_ROOT"

version="$(python3 scripts/version.py --platform android --field version)"
build="$(python3 scripts/version.py --platform android --field build)"
output="${FREEV6_OUTPUT_DIR:-$FREEV6_ROOT/dist/android/$version-b$build}"
artifact="FreeV6-$version-b$build-arm64.apk"
if [[ -e "$output/$artifact" || -e "$output/APK-SHA256SUMS" ]]; then
  printf 'Release output already exists: %s\n' "$output" >&2
  exit 1
fi

if [[ -z "${FREEV6_KEYSTORE:-}" ]]; then
  signing_dir="$(python3 scripts/android/prepare-signing.py)"
  if [[ ! -f "$signing_dir/password" ]]; then
    python3 - "$signing_dir/password" <<'PY'
import os, secrets
import sys
path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(secrets.token_urlsafe(32))
PY
  fi
  export FREEV6_KEYSTORE="$signing_dir/preview.jks"
  export FREEV6_STORE_PASSWORD="$(cat "$signing_dir/password")"
  export FREEV6_KEY_PASSWORD="$FREEV6_STORE_PASSWORD"
  export FREEV6_KEY_ALIAS=freev6-preview
  if [[ ! -f "$FREEV6_KEYSTORE" ]]; then
    keytool -genkeypair -keystore "$FREEV6_KEYSTORE" -storetype JKS \
      -alias "$FREEV6_KEY_ALIAS" -storepass:env FREEV6_STORE_PASSWORD \
      -keypass:env FREEV6_KEY_PASSWORD -keyalg RSA -keysize 3072 \
      -validity 10000 -dname "CN=FreeV6 Android" -noprompt
    chmod 600 "$FREEV6_KEYSTORE"
  fi
fi

for setting in FREEV6_STORE_PASSWORD FREEV6_KEY_ALIAS FREEV6_KEY_PASSWORD; do
  if [[ -z "${!setting:-}" ]]; then
    printf 'Missing signing setting: %s\n' "$setting" >&2
    exit 1
  fi
done
if [[ ! -f "$FREEV6_KEYSTORE" ]]; then
  printf 'Configured Android keystore does not exist\n' >&2
  exit 1
fi

cd apps/android
flutter pub get --enforce-lockfile
flutter build apk --release --target-platform android-arm64 --dart-define=APP_ENV=stable "$@"
cd "$FREEV6_ROOT"
mkdir -p "$output"
cp apps/android/build/app/outputs/flutter-apk/app-release.apk "$output/$artifact"
(cd "$output" && shasum -a 256 "$artifact" > APK-SHA256SUMS)
printf 'APK: %s\n' "$output/$artifact"
