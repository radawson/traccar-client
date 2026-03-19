# Changelog

## 9.9.0+132

- Added WebSocket command transport with deterministic selection and optional FCM fallback.
- Added Advanced transport controls (mode override slider, WebSocket enable toggle, probe action).
- Added four-color connection indicator on the main screen:
  - Blue: `Private (WebSocket)`
  - Green: `Connected (Firebase)`
  - Yellow: `Degraded`
  - Red: `Offline`
- Hardened Android 15 / GrapheneOS startup with preflight checks, runtime backend fallback, and improved diagnostics.

## 9.8.0+131

- Added a location-service fallback path for Android devices without Google Play Services.
- Introduced a `TrackingService` abstraction with two implementations:
  - `PluginTrackingService` (existing `flutter_background_geolocation` path)
  - `FallbackTrackingService` (LocationManager via `geolocator`, foreground task, manual upload)
- Switched app entry points (`main`, screens, push/config services) to use the tracking abstraction.
- Added Android foreground-service permissions and service declaration for fallback tracking.
- Improved startup resilience around service initialization and Play Services detection.
