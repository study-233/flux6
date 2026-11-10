#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$FREEV6_ROOT"

# Keep the preview key between builds so users can install updates in place.
# It is deliberately outside the source tree shipped with the APK.
if [[ -z "${FREEV6_KEYSTORE:-}" ]]; then
  mkdir -p build/mobile-signing
  if [[ ! -f build/mobile-signing/password ]]; then
    python3 - <<'PY'
import os, secrets
path = 'build/mobile-signing/password'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(secrets.token_urlsafe(32))
PY
  fi
  export FREEV6_KEYSTORE="$FREEV6_ROOT/build/mobile-signing/preview.jks"
  export FREEV6_STORE_PASSWORD="$(cat build/mobile-signing/password)"
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
