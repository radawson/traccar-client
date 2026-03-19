import 'dart:convert';
import 'dart:developer' as developer;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

class TransportLogService {
  static void event(String name, {Map<String, Object?> context = const {}}) {
    final suffix = context.isEmpty ? '' : ' ${jsonEncode(context)}';
    final message = '$name$suffix';
    developer.log(message, name: 'transport');
    try {
      FirebaseCrashlytics.instance.log('transport:$message');
    } catch (_) {}
  }

  static void error(
    String name,
    Object error, {
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) {
    final payload = {...context, 'error': error.toString()};
    event(name, context: payload);
    developer.log(
      name,
      name: 'transport',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
