# Changelog

## 9.8.0+131

- Added a location-service fallback path for Android devices without Google Play Services.
- Introduced a `TrackingService` abstraction with two implementations:
  - `PluginTrackingService` (existing `flutter_background_geolocation` path)
  - `FallbackTrackingService` (LocationManager via `geolocator`, foreground task, manual upload)
- Switched app entry points (`main`, screens, push/config services) to use the tracking abstraction.
- Added Android foreground-service permissions and service declaration for fallback tracking.
- Improved startup resilience around service initialization and Play Services detection.
