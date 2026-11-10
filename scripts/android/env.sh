#!/usr/bin/env bash
set -euo pipefail
FREEV6_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export XDG_CONFIG_HOME="$FREEV6_ROOT/build/flutter-toolchain/config"
export PUB_CACHE="$FREEV6_ROOT/build/flutter-toolchain/pub-cache"
export GOPATH="$FREEV6_ROOT/build/mobile-go"
export GOCACHE="$FREEV6_ROOT/build/mobile-go-cache"
if [[ -d "$FREEV6_ROOT/build/mobile-toolchain/rustup/toolchains" ]]; then
  export CARGO_HOME="${CARGO_HOME:-$FREEV6_ROOT/build/mobile-toolchain/cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-$FREEV6_ROOT/build/mobile-toolchain/rustup}"
fi
FREEV6_LOCAL_JDK="$FREEV6_ROOT/build/mobile-toolchain/jdk17/jdk-17.0.21+9/Contents/Home"
if [[ -n "${FREEV6_JAVA_HOME:-${JAVA_HOME:-}}" ]]; then
  export JAVA_HOME="${FREEV6_JAVA_HOME:-$JAVA_HOME}"
elif [[ -x "$FREEV6_LOCAL_JDK/bin/java" ]]; then
  export JAVA_HOME="${FREEV6_JAVA_HOME:-$FREEV6_LOCAL_JDK}"
else
  export JAVA_HOME="${FREEV6_JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
fi
export ANDROID_HOME="${FREEV6_ANDROID_SDK:-${ANDROID_HOME:-$FREEV6_ROOT/build/mobile-sdk}}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="${FREEV6_FLUTTER_SDK:-$FREEV6_ROOT/build/flutter-toolchain/flutter}/bin:$FREEV6_ROOT/build/go-toolchain/go/bin:${CARGO_HOME:-$FREEV6_ROOT/build/mobile-toolchain/cargo}/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
FREEV6_GRADLE_OPTIONS="$(python3 - <<'PY'
import os, shlex
from urllib.parse import urlparse
options = ['-Dorg.gradle.java.home=' + os.environ['JAVA_HOME']]
p = urlparse(os.environ.get('https_proxy', os.environ.get('HTTPS_PROXY', '')))
if p.hostname and p.port and not p.username:
    options += [f'-Dhttp.proxyHost={p.hostname}', f'-Dhttp.proxyPort={p.port}',
                f'-Dhttps.proxyHost={p.hostname}', f'-Dhttps.proxyPort={p.port}',
                '-Dhttp.nonProxyHosts=localhost']
print(' '.join(shlex.quote(option) for option in options))
PY
)"
export GRADLE_OPTS="${GRADLE_OPTS:-} $FREEV6_GRADLE_OPTIONS"
