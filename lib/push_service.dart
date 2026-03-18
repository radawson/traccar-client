import 'dart:developer' as developer;
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/tracking_services.dart';

import 'preferences.dart';

class PushService {
  static Future<void> init() async {
    if (!TrackingServices.instance.supportsPushCommands) {
      developer.log('Push service disabled in fallback mode');
      return;
    }
    await FirebaseMessaging.instance.requestPermission();
    FirebaseMessaging.onBackgroundMessage(pushServiceBackgroundHandler);
    FirebaseMessaging.onMessage.listen(_onMessage);
    FirebaseMessaging.instance.onTokenRefresh.listen(_uploadToken);
    TrackingServices.instance.onEnabledChange((enabled) async {
      if (enabled) {
        try {
          _uploadToken(await FirebaseMessaging.instance.getToken());
        } catch (error) {
          developer.log('Failed to get notificaion token', error: error);
        }
      }
    });
  }

  static Future<void> _onMessage(RemoteMessage message) async {
    final command = message.data['command'];
    FirebaseCrashlytics.instance.log('push_command: $command');
    switch (command) {
      case 'positionSingle':
        try {
          await TrackingServices.instance.getCurrentPosition(
            extras: const {'remote': true},
          );
        } catch (error) {
          developer.log('Failed to get position', error: error);
        }
      case 'positionPeriodic':
        await TrackingServices.instance.start();
      case 'positionStop':
        await TrackingServices.instance.stop();
      case 'factoryReset':
        await PasswordService.setPassword('');
    }
  }

  static Future<void> _uploadToken(String? token) async {
    if (token == null) return;
    final id = Preferences.instance.getString(Preferences.id);
    final url = Preferences.instance.getString(Preferences.url);
    if (id == null || url == null) return;
    try {
      final request = await HttpClient().postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.parse('application/x-www-form-urlencoded');
      request.write('id=${Uri.encodeComponent(id)}&notificationToken=${Uri.encodeComponent(token)}');
      await request.close();
    } catch (error) {
      developer.log('Failed to upload token', error: error);
    }
  }
}

@pragma('vm:entry-point')
Future<void> pushServiceBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await Preferences.init();
  await TrackingServices.initialize();
  if (!TrackingServices.instance.supportsPushCommands) return;
  FirebaseCrashlytics.instance.log('push_background_handler');
  await PushService._onMessage(message);
}
