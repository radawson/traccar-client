import 'dart:io';

import 'package:google_api_availability/google_api_availability.dart';

import 'fallback_tracking_service.dart';
import 'plugin_tracking_service.dart';
import 'tracking_service.dart';
import 'transport_log_service.dart';

class TrackingServices {
  static late TrackingService instance;
  static bool playServicesAvailable = true;
  static String activeTrackingBackend = 'unknown';
  static String activeCommandTransport = 'none';

  static Future<void> initialize() async {
    playServicesAvailable = true;
    if (Platform.isAndroid) {
      try {
        final status =
            await GoogleApiAvailability.instance
                .checkGooglePlayServicesAvailability();
        playServicesAvailable =
            status == GooglePlayServicesAvailability.success;
      } catch (_) {
        playServicesAvailable = false;
      }
    }
    if (Platform.isAndroid) {
      final pluginService = PluginTrackingService();
      try {
        await pluginService.init();
        instance = _ResilientAndroidTrackingService(pluginService);
        activeTrackingBackend = 'plugin';
        TransportLogService.event(
          'tracking_backend_selected',
          context: {'backend': activeTrackingBackend},
        );
        return;
      } catch (error) {
        final fallbackService = FallbackTrackingService();
        await fallbackService.init();
        instance = fallbackService;
        activeTrackingBackend = 'fallback';
        TransportLogService.error(
          'tracking_backend_plugin_init_failed',
          error,
          context: {'backend': activeTrackingBackend},
        );
        return;
      }
    }

    final pluginService = PluginTrackingService();
    await pluginService.init();
    instance = pluginService;
    activeTrackingBackend = 'plugin';
  }
}

class _ResilientAndroidTrackingService implements TrackingService {
  TrackingService _activeService;
  final List<EnabledChangeCallback> _enabledCallbacks = [];
  final List<MotionChangeCallback> _motionCallbacks = [];

  _ResilientAndroidTrackingService(this._activeService) {
    _bindCallbacks(_activeService);
  }

  @override
  bool get isFallback => _activeService.isFallback;

  @override
  bool get supportsPushCommands => _activeService.supportsPushCommands;

  @override
  Future<void> init() => _activeService.init();

  @override
  Future<void> start() async {
    final preflight = await AndroidTrackingPreflight.run();
    if (!preflight.canStartTracking) {
      TransportLogService.event(
        'android_preflight_blocked_noninteractive_start',
        context: preflight.toLogContext(),
      );
      throw StateError(preflight.primaryMessage);
    }
    if (preflight.warnings.isNotEmpty) {
      TransportLogService.event(
        'android_preflight_warning_noninteractive_start',
        context: preflight.toLogContext(),
      );
    }
    try {
      await _activeService.start();
    } catch (error, stackTrace) {
      if (_activeService.isFallback) rethrow;
      TransportLogService.error(
        'tracking_backend_plugin_start_failed',
        error,
        stackTrace: stackTrace,
      );
      await _promoteToFallback(reason: 'plugin_start_failed');
      await _activeService.start();
    }
  }

  @override
  Future<void> stop() => _activeService.stop();

  @override
  Future<TrackingState> getState() => _activeService.getState();

  @override
  Future<TrackingProviderState> getProviderState() =>
      _activeService.getProviderState();

  @override
  Future<void> getCurrentPosition({Map<String, dynamic>? extras}) =>
      _activeService.getCurrentPosition(extras: extras);

  @override
  Future<void> setConfig() => _activeService.setConfig();

  @override
  void onEnabledChange(EnabledChangeCallback callback) {
    _enabledCallbacks.add(callback);
  }

  @override
  void onMotionChange(MotionChangeCallback callback) {
    _motionCallbacks.add(callback);
  }

  void _bindCallbacks(TrackingService service) {
    service.onEnabledChange((enabled) {
      for (final callback in _enabledCallbacks) {
        callback(enabled);
      }
    });
    service.onMotionChange((location) {
      for (final callback in _motionCallbacks) {
        callback(location);
      }
    });
  }

  Future<void> _promoteToFallback({required String reason}) async {
    final fallbackService = FallbackTrackingService();
    await fallbackService.init();
    _activeService = fallbackService;
    _bindCallbacks(fallbackService);
    TrackingServices.activeTrackingBackend = 'fallback';
    TransportLogService.event(
      'tracking_backend_fallback_promoted',
      context: {'reason': reason},
    );
  }
}
