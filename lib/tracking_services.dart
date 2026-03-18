import 'dart:io';

import 'package:google_api_availability/google_api_availability.dart';

import 'fallback_tracking_service.dart';
import 'plugin_tracking_service.dart';
import 'tracking_service.dart';

class TrackingServices {
  static late TrackingService instance;
  static bool playServicesAvailable = true;

  static Future<void> initialize() async {
    playServicesAvailable = true;
    if (Platform.isAndroid) {
      try {
        final status = await GoogleApiAvailability.instance
            .checkGooglePlayServicesAvailability();
        playServicesAvailable = status == GooglePlayServicesAvailability.success;
      } catch (_) {
        playServicesAvailable = false;
      }
    }
    instance = playServicesAvailable
        ? PluginTrackingService()
        : FallbackTrackingService();
    await instance.init();
  }
}
