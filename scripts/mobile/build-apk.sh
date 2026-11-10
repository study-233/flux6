#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$FREEV6_ROOT"

if [[ -z "${FREEV6_KEYSTORE:-}" ]]; then
  signing_dir="$(python3 scripts/mobile/prepare-signing.py)"
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
      -validity 10000 -dname "CN=FreeV6 Android Preview" -noprompt
    chmod 600 "$FREEV6_KEYSTORE"
  fi
fi

cd mobile
flutter pub get
flutter build apk --release --target-platform android-arm64 "$@"
cd "$FREEV6_ROOT"
mkdir -p dist/android
cp mobile/build/app/outputs/flutter-apk/app-release.apk dist/android/FreeV6-0.1.2-preview-arm64.apk
shasum -a 256 dist/android/FreeV6-0.1.2-preview-arm64.apk > dist/android/SHA256SUMS
printf 'APK: %s\n' "$FREEV6_ROOT/dist/android/FreeV6-0.1.2-preview-arm64.apk"
