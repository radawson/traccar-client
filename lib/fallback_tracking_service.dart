import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:flutter_foreground_task/flutter_foreground_task.dart' as fft;
import 'package:geolocator/geolocator.dart';

import 'location_cache.dart';
import 'preferences.dart';
import 'tracking_service.dart';
import 'transport_log_service.dart';

class AndroidPreflightReport {
  final bool locationServicesEnabled;
  final LocationPermission locationPermission;
  final bool hasForegroundLocation;
  final bool hasBackgroundLocation;
  final bool notificationsGranted;
  final String notificationStatus;
  final bool batteryOptimizationIgnored;
  final bool batteryOptimizationKnown;
  final List<String> blockingIssues;
  final List<String> warnings;

  const AndroidPreflightReport({
    required this.locationServicesEnabled,
    required this.locationPermission,
    required this.hasForegroundLocation,
    required this.hasBackgroundLocation,
    required this.notificationsGranted,
    required this.notificationStatus,
    required this.batteryOptimizationIgnored,
    required this.batteryOptimizationKnown,
    required this.blockingIssues,
    required this.warnings,
  });

  bool get canStartTracking => blockingIssues.isEmpty;

  String get primaryMessage =>
      canStartTracking
          ? (warnings.isNotEmpty ? warnings.first : 'Ready for tracking.')
          : blockingIssues.first;

  Map<String, Object?> toLogContext() {
    return {
      'locationServicesEnabled': locationServicesEnabled,
      'locationPermission': locationPermission.name,
      'hasForegroundLocation': hasForegroundLocation,
      'hasBackgroundLocation': hasBackgroundLocation,
      'notificationsGranted': notificationsGranted,
      'notificationStatus': notificationStatus,
      'batteryOptimizationIgnored': batteryOptimizationIgnored,
      'batteryOptimizationKnown': batteryOptimizationKnown,
      'blockingIssues': blockingIssues,
      'warnings': warnings,
    };
  }
}

class AndroidTrackingPreflight {
  static Future<AndroidPreflightReport> run({
    bool requestPermissions = false,
  }) async {
    final blockingIssues = <String>[];
    final warnings = <String>[];

    final locationServicesEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationServicesEnabled) {
      blockingIssues.add('Location services are disabled.');
    }

    var locationPermission = await Geolocator.checkPermission();
    if (requestPermissions && locationPermission == LocationPermission.denied) {
      locationPermission = await Geolocator.requestPermission();
    }
    if (requestPermissions &&
        Platform.isAndroid &&
        locationPermission == LocationPermission.whileInUse) {
      locationPermission = await Geolocator.requestPermission();
    }

    final hasForegroundLocation =
        locationPermission == LocationPermission.whileInUse ||
        locationPermission == LocationPermission.always;
    final hasBackgroundLocation =
        !Platform.isAndroid || locationPermission == LocationPermission.always;

    if (!hasForegroundLocation) {
      blockingIssues.add('Foreground location permission is required.');
    }
    if (Platform.isAndroid && !hasBackgroundLocation) {
      blockingIssues.add(
        'Background location must be "Allow all the time" on Android 15.',
      );
    }

    var notificationsGranted = true;
    var notificationStatus = 'unknown';
    try {
      var notificationSettings =
          await FirebaseMessaging.instance.getNotificationSettings();
      if (requestPermissions &&
          notificationSettings.authorizationStatus ==
              AuthorizationStatus.notDetermined) {
        notificationSettings = await FirebaseMessaging.instance
            .requestPermission(alert: true, badge: true, sound: true);
      }
      notificationStatus = notificationSettings.authorizationStatus.name;
      notificationsGranted =
          notificationSettings.authorizationStatus ==
              AuthorizationStatus.authorized ||
          notificationSettings.authorizationStatus ==
              AuthorizationStatus.provisional;
    } catch (_) {
      notificationsGranted = false;
      notificationStatus = 'unavailable';
    }
    if (!notificationsGranted) {
      warnings.add(
        'Notifications are denied or unavailable; background command delivery may be limited.',
      );
    }

    var batteryOptimizationIgnored = true;
    var batteryOptimizationKnown = false;
    try {
      batteryOptimizationIgnored =
          await bg.DeviceSettings.isIgnoringBatteryOptimizations;
      batteryOptimizationKnown = true;
    } catch (_) {
      batteryOptimizationIgnored = false;
      batteryOptimizationKnown = false;
    }
    if (batteryOptimizationKnown && !batteryOptimizationIgnored) {
      warnings.add(
        'Battery optimization is enabled and can reduce background reliability.',
      );
    }

    final report = AndroidPreflightReport(
      locationServicesEnabled: locationServicesEnabled,
      locationPermission: locationPermission,
      hasForegroundLocation: hasForegroundLocation,
      hasBackgroundLocation: hasBackgroundLocation,
      notificationsGranted: notificationsGranted,
      notificationStatus: notificationStatus,
      batteryOptimizationIgnored: batteryOptimizationIgnored,
      batteryOptimizationKnown: batteryOptimizationKnown,
      blockingIssues: List.unmodifiable(blockingIssues),
      warnings: List.unmodifiable(warnings),
    );

    TransportLogService.event(
      'android_preflight_result',
      context: report.toLogContext(),
    );
    return report;
  }
}

class FallbackTrackingService implements TrackingService {
  final List<EnabledChangeCallback> _enabledCallbacks = [];
  final List<MotionChangeCallback> _motionCallbacks = [];
  final List<TrackingLocation> _buffer = [];

  StreamSubscription<Position>? _positionSubscription;
  Timer? _heartbeatTimer;
  bool _enabled = false;
  bool _initializedForegroundTask = false;

  @override
  bool get isFallback => true;

  @override
  bool get supportsPushCommands => false;

  @override
  Future<void> init() async {
    if (Platform.isAndroid) {
      _initializeForegroundTask();
    }
    TransportLogService.event('fallback_geolocation_init');
  }

  @override
  Future<void> start() async {
    await _ensurePermission();
    if (Platform.isAndroid) {
      await _startForegroundService();
    }
    await _startPositionStream();
    _startHeartbeat();
    _enabled = true;
    TransportLogService.event('fallback_geolocation_start');
    _notifyEnabled(true);
  }

  @override
  Future<void> stop() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (Platform.isAndroid) {
      await fft.FlutterForegroundTask.stopService();
    }
    _enabled = false;
    TransportLogService.event('fallback_geolocation_stop');
    _notifyEnabled(false);
  }

  @override
  Future<TrackingState> getState() async {
    return TrackingState(enabled: _enabled, isMoving: true);
  }

  @override
  Future<TrackingProviderState> getProviderState() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return const TrackingProviderState(TrackingAuthorizationStatus.denied);
    }
    return const TrackingProviderState(TrackingAuthorizationStatus.authorized);
  }

  @override
  Future<void> getCurrentPosition({Map<String, dynamic>? extras}) async {
    await _ensurePermission();
    final position = await Geolocator.getCurrentPosition(
      locationSettings: _locationSettings(),
    );
    final location = _fromPosition(position, extras: extras);
    await _handleLocation(location);
  }

  @override
  Future<void> setConfig() async {
    // Fallback mode applies settings directly while processing stream updates.
  }

  @override
  void onEnabledChange(EnabledChangeCallback callback) {
    _enabledCallbacks.add(callback);
  }

  @override
  void onMotionChange(MotionChangeCallback callback) {
    _motionCallbacks.add(callback);
  }

  void _initializeForegroundTask() {
    if (_initializedForegroundTask) return;
    fft.FlutterForegroundTask.init(
      androidNotificationOptions: fft.AndroidNotificationOptions(
        channelId: 'tracking_fallback',
        channelName: 'Tracking Fallback',
        channelDescription: 'Location tracking without Google Play Services',
      ),
      iosNotificationOptions: fft.IOSNotificationOptions(),
      foregroundTaskOptions: fft.ForegroundTaskOptions(
        eventAction: fft.ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
    _initializedForegroundTask = true;
  }

  Future<void> _startForegroundService() async {
    _initializeForegroundTask();
    await fft.FlutterForegroundTask.startService(
      notificationTitle: 'Traccar Client',
      notificationText: 'Tracking with reduced accuracy fallback',
    );
  }

  Future<void> _startPositionStream() async {
    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _locationSettings(),
    ).listen((position) async {
      final location = _fromPosition(position);
      await _handleLocation(location);
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    final heartbeat = Preferences.instance.getInt(Preferences.heartbeat) ?? 0;
    if (heartbeat <= 0) return;
    _heartbeatTimer = Timer.periodic(Duration(seconds: heartbeat), (_) async {
      await getCurrentPosition(extras: const {'heartbeat': true});
    });
  }

  LocationSettings _locationSettings() {
    if (!Platform.isAndroid) {
      return LocationSettings(accuracy: _desiredAccuracy());
    }
    final intervalMs =
        (Preferences.instance.getInt(Preferences.interval) ?? 30) * 1000;
    return AndroidSettings(
      accuracy: _desiredAccuracy(),
      distanceFilter: Preferences.instance.getInt(Preferences.distance) ?? 0,
      intervalDuration: Duration(milliseconds: intervalMs),
      forceLocationManager: true,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Traccar Client',
        notificationText: 'Tracking location in background',
        enableWakeLock: true,
      ),
    );
  }

  LocationAccuracy _desiredAccuracy() {
    return switch (Preferences.instance.getString(Preferences.accuracy)) {
      'highest' => LocationAccuracy.bestForNavigation,
      'high' => LocationAccuracy.high,
      'low' => LocationAccuracy.low,
      _ => LocationAccuracy.medium,
    };
  }

  TrackingLocation _fromPosition(
    Position position, {
    Map<String, dynamic>? extras,
  }) {
    return TrackingLocation(
      timestamp: position.timestamp.toUtc().toIso8601String(),
      latitude: position.latitude,
      longitude: position.longitude,
      heading: position.heading,
      isMoving: true,
      extras: extras,
    );
  }

  Future<void> _handleLocation(TrackingLocation location) async {
    await LocationCache.set(location);
    _notifyMotion(location);
    _buffer.add(location);
    await _flushBuffer();
  }

  Future<void> _flushBuffer() async {
    if (_buffer.isEmpty) return;
    final pending = List<TrackingLocation>.from(_buffer);
    for (final location in pending) {
      try {
        await _sendLocation(location);
        _buffer.remove(location);
      } catch (error) {
        TransportLogService.error('fallback_location_send_failed', error);
        break;
      }
    }
  }

  Future<void> _sendLocation(TrackingLocation location) async {
    final id = Preferences.instance.getString(Preferences.id);
    final url = _formatUrl(Preferences.instance.getString(Preferences.url));
    if (id == null || url == null) {
      throw StateError('Missing tracking configuration');
    }
    final request = await HttpClient().postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'device_id': id,
        'timestamp': location.timestamp,
        'coords': {
          'latitude': location.latitude,
          'longitude': location.longitude,
          'heading': location.heading,
        },
        'is_moving': true,
        'extras': location.extras ?? {},
        '_':
            '&id=$id&lat=${location.latitude}&lon=${location.longitude}&timestamp=${Uri.encodeComponent(location.timestamp)}&',
      }),
    );
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Location upload failed: ${response.statusCode}');
    }
  }

  String? _formatUrl(String? url) {
    if (url == null) return null;
    final uri = Uri.parse(url);
    if (uri.path.isEmpty && !url.endsWith('/')) return '$url/';
    return url;
  }

  Future<void> _ensurePermission() async {
    final report = await AndroidTrackingPreflight.run(requestPermissions: true);
    if (!report.canStartTracking) {
      throw Exception(report.primaryMessage);
    }
  }

  void _notifyEnabled(bool enabled) {
    for (final callback in _enabledCallbacks) {
      callback(enabled);
    }
  }

  void _notifyMotion(TrackingLocation location) {
    for (final callback in _motionCallbacks) {
      callback(location);
    }
  }
}
