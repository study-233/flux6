# Flux6 releases

## v0.1.2 (2026-11-15)

**Features**
- **Android** The network speed card charts live uploads and downloads. Tap it to see monthly and lifetime usage.
- **Windows** Choose a node automatically using speed measurements on the current network, pin one manually, or test latency and download speed for a group.
- **macOS** Flux6 checks for updates at startup by default and asks before installing and reopening. You can turn off startup checks in General settings.
- **Android** Download updates directly from the release. Android verifies the signature and asks before installing.
- **Upgrading from Android 0.1.1** Install the new APK over the existing app once to enable future in-app updates.

**Bug Fixes**
- **Windows** Monthly and lifetime usage now include short connections that open and close between samples.
- **macOS** Flux6 can restore the network service when its launch configuration is missing.

## v0.1.1 (2026-11-12)

**Features**
- **macOS** Check for updates in the app menu or General settings. Flux6 verifies the signed feed and archive before installing and restarting.
- **Android** Check for updates in About or enable checks at startup. Flux6 verifies the APK checksum before Android asks you to install it.
- **Upgrading from 0.1.0** Install 0.1.1 manually once to enable future in-app updates.

## v0.1.0 (2026-11-10)

**Features**
- **Flux6** Unified project, application and installer branding while retaining signing identities, package IDs and existing settings.
- **macOS** First public release for Apple Silicon and macOS 14 or later, with DMG, application ZIP and Homebrew installation.
- **Android** First public release for ARM64 devices running Android 7.0 or later, distributed as an APK.
- **Connection** Campus IPv6 connectivity, node selection and WARP egress management.
- **Source** Corresponding source archives are available alongside each platform's installers.

**Bug Fixes**
- **macOS** Allow normal exit when the service installation is incomplete and no network session is owned, while preserving active-session recovery checks.
