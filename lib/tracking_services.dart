import 'dart:io';

import 'package:google_api_availability/google_api_availability.dart';

import 'fallback_tracking_service.dart';
import 'plugin_tracking_service.dart';
import 'tracking_service.dart';

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
        instance = pluginService;
        activeTrackingBackend = 'plugin';
        return;
      } catch (_) {
        final fallbackService = FallbackTrackingService();
        await fallbackService.init();
        instance = fallbackService;
        activeTrackingBackend = 'fallback';
        return;
      }
    }

    final pluginService = PluginTrackingService();
    await pluginService.init();
    instance = pluginService;
    activeTrackingBackend = 'plugin';
  }
}
