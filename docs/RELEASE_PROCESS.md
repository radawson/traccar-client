# Release Process

This document describes how to build signed Android artifacts for testing and Google Play upload.

## Prerequisites

- Flutter SDK available at `/home/torvaldsl/develop/flutter/bin`
- Android SDK / build tools installed
- Upload keystore available at `~/.ssh/my-release-key.jks`
- `android/key.properties` configured with the correct passwords and alias

## Signing Configuration

The Android app is configured to read signing settings from:

1. `android/key.properties` (preferred)
2. `../../environment/key.properties` (legacy fallback)

Current local file format:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=app-signing-key
storeFile=~/.ssh/my-release-key.jks
```

Notes:

- `android/key.properties` is gitignored and must never be committed.
- `storeFile` supports `~` home expansion.
- For Google Play, this is your upload key (not Google's app signing key).

## Build a Signed Release APK (Testing)

From the project root:

```bash
export PATH="/home/torvaldsl/develop/flutter/bin:$PATH"
flutter clean
flutter pub get
flutter build apk --release
```

Output:

- `build/app/outputs/flutter-apk/app-release.apk`

## Build a Signed AAB (Google Play Upload)

From the project root:

```bash
export PATH="/home/torvaldsl/develop/flutter/bin:$PATH"
flutter clean
flutter pub get
flutter build appbundle --release
```

Output:

- `build/app/outputs/bundle/release/app-release.aab`

## Verify Signature

Use Android build tools:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

## Command Transport Configuration

Remote commands now support WebSocket as primary transport with optional FCM fallback.

Configure in app settings (Advanced):

- `WebSocket URL` (use `wss://...`)
- `WebSocket Token` (device auth token)
- `Enable WebSocket transport`
- `Command transport mode` (slider: `Auto`, `WebSocket only`, `FCM only`, `Disabled`)
- `Use FCM fallback` (enabled by default)
- `Test WebSocket connection`

Behavior:

- `Auto` mode:
  - Android: prefer `websocket`, then `fcm`.
  - iOS: keep Firebase path and prefer `fcm`, with automatic fallback to `websocket`.
- `WebSocket only`: commands run only over WebSocket.
- `FCM only`: commands run only over Firebase messaging.
- `Disabled`: remote command transport is disabled.
- If no command transport is available, location uploads continue via HTTPS.

Protocol details are documented in `docs/WEBSOCKET_COMMAND_CONTRACT.md`.

## GrapheneOS 15 Validation Matrix

Validate all scenarios before release:

1. Graphene profile with sandboxed Play Services:
   - WebSocket configured: verify commands arrive over WebSocket.
   - WebSocket disabled/failing + FCM fallback enabled: verify commands arrive over FCM.
2. Graphene profile without Play Services:
   - WebSocket configured: verify remote commands still work.
   - WebSocket disabled/failing: verify clear no-command diagnostics.
3. Resilience:
   - Toggle network off/on and confirm reconnect and command recovery.
   - Force-stop app and restart tracking.
   - Reboot device and validate tracking + command transport status.
4. Permissions:
   - Downgrade location permission from "Allow all the time" to "While in use" and verify graceful failures.
   - Deny notifications and confirm app still tracks but reports transport/notification state clearly.
5. iOS behavior:
   - In `Auto` mode verify Firebase commands are primary.
   - Disable or break Firebase path and verify automatic fallback to WebSocket.

## Troubleshooting

- If signing is not applied, check that `android/key.properties` exists and all values are correct.
- If alias errors appear, verify `keyAlias` matches the keystore alias.
- If path errors appear, verify `storeFile` points to an existing `.jks`.
