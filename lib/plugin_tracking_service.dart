import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:wakelock_partial_android/wakelock_partial_android.dart';

import 'location_cache.dart';
import 'preferences.dart';
import 'tracking_service.dart';

class PluginTrackingService implements TrackingService {
  final List<EnabledChangeCallback> _enabledCallbacks = [];
  final List<MotionChangeCallback> _motionCallbacks = [];

  @override
  bool get isFallback => false;

  @override
  bool get supportsPushCommands => true;

  @override
  Future<void> init() async {
    await bg.BackgroundGeolocation.ready(Preferences.geolocationConfig());
    if (Platform.isAndroid) {
      await bg.BackgroundGeolocation.registerHeadlessTask(pluginHeadlessTask);
    }
    try {
      FirebaseCrashlytics.instance.log('geolocation_init');
    } catch (_) {}
    bg.BackgroundGeolocation.onEnabledChange(onEnabledChangeInternal);
    bg.BackgroundGeolocation.onMotionChange(onMotionChangeInternal);
    bg.BackgroundGeolocation.onHeartbeat(onHeartbeatInternal);
    bg.BackgroundGeolocation.onLocation(
      onLocationInternal,
      (bg.LocationError error) {
        developer.log('Location error', error: error);
      },
    );
  }

  @override
  Future<void> start() async {
    await bg.BackgroundGeolocation.start();
  }

  @override
  Future<void> stop() async {
    await bg.BackgroundGeolocation.stop();
  }

  @override
  Future<TrackingState> getState() async {
    final state = await bg.BackgroundGeolocation.state;
    return TrackingState(
      enabled: state.enabled,
      isMoving: state.isMoving == true,
    );
  }

  @override
  Future<TrackingProviderState> getProviderState() async {
    final providerState = await bg.BackgroundGeolocation.providerState;
    return TrackingProviderState(_mapProviderStatus(providerState.status));
  }

  @override
  Future<void> getCurrentPosition({Map<String, dynamic>? extras}) async {
    await bg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      persist: true,
      extras: extras ?? const {},
    );
  }

  @override
  Future<void> setConfig() async {
    await bg.BackgroundGeolocation.setConfig(Preferences.geolocationConfig());
  }

  @override
  void onEnabledChange(EnabledChangeCallback callback) {
    _enabledCallbacks.add(callback);
  }

  @override
  void onMotionChange(MotionChangeCallback callback) {
    _motionCallbacks.add(callback);
  }

  Future<void> onEnabledChangeInternal(bool enabled) async {
    try {
      FirebaseCrashlytics.instance.log('geolocation_enabled:$enabled');
    } catch (_) {}
    if (Preferences.instance.getBool(Preferences.wakelock) ?? false) {
      if (!enabled) {
        await WakelockPartialAndroid.release();
      }
    }
    for (final callback in _enabledCallbacks) {
      callback(enabled);
    }
  }

  Future<void> onMotionChangeInternal(bg.Location location) async {
    try {
      FirebaseCrashlytics.instance.log('geolocation_motion:${location.isMoving}');
    } catch (_) {}
    if (Preferences.instance.getBool(Preferences.wakelock) ?? false) {
      if (location.isMoving) {
        await WakelockPartialAndroid.acquire();
      } else {
        await WakelockPartialAndroid.release();
      }
    }
    final trackingLocation = _fromBgLocation(location);
    for (final callback in _motionCallbacks) {
      callback(trackingLocation);
    }
  }

  Future<void> onHeartbeatInternal(bg.HeartbeatEvent event) async {
    await bg.BackgroundGeolocation.getCurrentPosition(
      samples: 1,
      persist: true,
      extras: const {'heartbeat': true},
    );
  }

  Future<void> onLocationInternal(bg.Location location) async {
    final trackingLocation = _fromBgLocation(location);
    if (_shouldDelete(trackingLocation)) {
      try {
        await bg.BackgroundGeolocation.destroyLocation(location.uuid);
      } catch (error) {
        developer.log('Failed to delete location', error: error);
      }
    } else {
      await LocationCache.set(trackingLocation);
      try {
        await bg.BackgroundGeolocation.sync();
      } catch (error) {
        developer.log('Failed to send location', error: error);
      }
    }
  }

  TrackingAuthorizationStatus _mapProviderStatus(int status) {
    if (status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_DENIED) {
      return TrackingAuthorizationStatus.denied;
    }
    if (status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_RESTRICTED) {
      return TrackingAuthorizationStatus.restricted;
    }
    if (status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_ALWAYS ||
        status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_WHEN_IN_USE) {
      return TrackingAuthorizationStatus.authorized;
    }
    return TrackingAuthorizationStatus.unknown;
  }

  TrackingLocation _fromBgLocation(bg.Location location) {
    return TrackingLocation(
      timestamp: location.timestamp,
      latitude: location.coords.latitude,
      longitude: location.coords.longitude,
      heading: location.coords.heading,
      isMoving: location.isMoving,
      extras: location.extras?.cast<String, dynamic>(),
    );
  }

  bool _shouldDelete(TrackingLocation location) {
    if (!location.isMoving) return false;
    if (location.extras?.isNotEmpty == true) return false;

    final lastLocation = LocationCache.get();
    if (lastLocation == null) return false;

    final isHighestAccuracy =
        Preferences.instance.getString(Preferences.accuracy) == 'highest';
    final duration = DateTime.parse(location.timestamp)
        .difference(DateTime.parse(lastLocation.timestamp))
        .inSeconds;

    if (!isHighestAccuracy) {
      final fastestInterval =
          Preferences.instance.getInt(Preferences.fastestInterval);
      if (fastestInterval != null && duration < fastestInterval) return true;
    }

    final distance = _distance(lastLocation, location);

    final distanceFilter = Preferences.instance.getInt(Preferences.distance) ?? 0;
    if (distanceFilter > 0 && distance >= distanceFilter) return false;

    if (distanceFilter == 0 || isHighestAccuracy) {
      final intervalFilter = Preferences.instance.getInt(Preferences.interval) ?? 0;
      if (intervalFilter > 0 && duration >= intervalFilter) return false;
    }

    if (isHighestAccuracy &&
        lastLocation.heading >= 0 &&
        location.heading > 0) {
      final angle = (location.heading - lastLocation.heading).abs();
      final angleFilter = Preferences.instance.getInt(Preferences.angle) ?? 0;
      if (angleFilter > 0 && angle >= angleFilter) return false;
    }

    return true;
  }

  double _distance(CachedLocation from, TrackingLocation to) {
    const earthRadius = 6371008.8; // meters
    final dLat = _degToRad(to.latitude - from.latitude);
    final dLon = _degToRad(to.longitude - from.longitude);
    final sinLat = sin(dLat / 2);
    final sinLon = sin(dLon / 2);
    final a = sinLat * sinLat +
        cos(_degToRad(from.latitude)) *
            cos(_degToRad(to.latitude)) *
            sinLon *
            sinLon;
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _degToRad(double degree) => degree * pi / 180.0;
}

Future<void>? _firebaseInitialization;

@pragma('vm:entry-point')
void pluginHeadlessTask(bg.HeadlessEvent headlessEvent) async {
  await (_firebaseInitialization ??= Firebase.initializeApp());
  await Preferences.init();
  final service = PluginTrackingService();
  try {
    FirebaseCrashlytics.instance.log('geolocation_headless:${headlessEvent.name}');
  } catch (_) {}
  switch (headlessEvent.name) {
    case bg.Event.ENABLEDCHANGE:
      await service.onEnabledChangeInternal(headlessEvent.event);
    case bg.Event.MOTIONCHANGE:
      await service.onMotionChangeInternal(headlessEvent.event);
    case bg.Event.HEARTBEAT:
      await service.onHeartbeatInternal(headlessEvent.event);
    case bg.Event.LOCATION:
      await service.onLocationInternal(headlessEvent.event);
  }
}
