import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:traccar_client/main.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/push_service.dart';
import 'package:traccar_client/preferences.dart';
import 'package:traccar_client/transport_log_service.dart';
import 'package:traccar_client/tracking_service.dart';
import 'package:traccar_client/tracking_services.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;

import 'fallback_tracking_service.dart';
import 'l10n/app_localizations.dart';
import 'settings_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool trackingEnabled = false;
  bool? isMoving;

  @override
  void initState() {
    super.initState();
    _initState();
  }

  void _initState() async {
    final state = await TrackingServices.instance.getState();
    setState(() {
      trackingEnabled = state.enabled;
      isMoving = state.isMoving;
    });
    TrackingServices.instance.onEnabledChange((bool enabled) {
      setState(() {
        trackingEnabled = enabled;
      });
    });
    TrackingServices.instance.onMotionChange((TrackingLocation location) {
      setState(() {
        isMoving = location.isMoving;
      });
    });
  }

  Future<void> _checkBatteryOptimizations(BuildContext context) async {
    try {
      if (!await bg.DeviceSettings.isIgnoringBatteryOptimizations) {
        final request =
            await bg.DeviceSettings.showIgnoreBatteryOptimizations();
        if (!request.seen && context.mounted) {
          showDialog(
            context: context,
            builder:
                (_) => AlertDialog(
                  scrollable: true,
                  content: Text(
                    AppLocalizations.of(context)!.optimizationMessage,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        bg.DeviceSettings.show(request);
                      },
                      child: Text(AppLocalizations.of(context)!.okButton),
                    ),
                  ],
                ),
          );
        }
      }
    } catch (error) {
      debugPrint(error.toString());
    }
  }

  Future<bool> _runAndroidPreflightBeforeStart() async {
    if (!Platform.isAndroid) return true;
    final report = await AndroidTrackingPreflight.run(requestPermissions: true);
    if (!mounted) return report.canStartTracking;

    if (!report.canStartTracking) {
      TransportLogService.event(
        'android_preflight_blocked_start',
        context: report.toLogContext(),
      );
      messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(report.primaryMessage),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: AppLocalizations.of(context)!.settingsTitle,
            onPressed:
                () =>
                    AppSettings.openAppSettings(type: AppSettingsType.settings),
          ),
        ),
      );
      return false;
    }

    if (report.warnings.isNotEmpty) {
      messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(report.primaryMessage),
          duration: const Duration(seconds: 4),
        ),
      );
    }
    return true;
  }

  Widget _buildTrackingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.trackingTitle),
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.idLabel),
              subtitle: Text(
                Preferences.instance.getString(Preferences.id) ?? '',
              ),
            ),
            ValueListenableBuilder<CommandDiagnostics>(
              valueListenable: PushService.diagnostics,
              builder: (context, diagnostics, _) {
                final lastCommand =
                    diagnostics.lastCommandAt == null
                        ? 'never'
                        : diagnostics.lastCommandAt!
                            .toLocal()
                            .toIso8601String();
                final reconnectReason = diagnostics.lastReconnectReason ?? '-';
                final lastError = diagnostics.lastError ?? '-';
                final transportInfo = PushService.availabilityMessage;
                return Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Tracking backend'),
                      subtitle: Text(TrackingServices.activeTrackingBackend),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Configured mode'),
                      subtitle: Text(PushService.configuredModeName),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Command transport'),
                      subtitle: Text(TrackingServices.activeCommandTransport),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('WebSocket'),
                      subtitle: Text(
                        diagnostics.websocketEnabled
                            ? (diagnostics.websocketConfigured
                                ? (diagnostics.websocketConnected
                                    ? 'connected'
                                    : 'disconnected')
                                : 'not configured')
                            : 'disabled',
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('FCM availability'),
                      subtitle: Text(
                        diagnostics.fcmEnabled
                            ? (diagnostics.fcmAvailable
                                ? 'available'
                                : 'unavailable')
                            : 'disabled',
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Last command'),
                      subtitle: Text(lastCommand),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Reconnect reason'),
                      subtitle: Text(reconnectReason),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Last command error'),
                      subtitle: Text(lastError),
                    ),
                    if (transportInfo != null)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Transport notice'),
                        subtitle: Text(transportInfo),
                      ),
                  ],
                );
              },
            ),
            if (Platform.isAndroid) ...[
              Text(
                AppLocalizations.of(context)!.disclosureMessage,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.trackingLabel),
              value: trackingEnabled,
              activeTrackColor:
                  isMoving == false
                      ? Theme.of(context).colorScheme.secondary
                      : null,
              onChanged: (bool value) async {
                if (await PasswordService.authenticate(context) && mounted) {
                  if (value) {
                    try {
                      final preflightReady =
                          await _runAndroidPreflightBeforeStart();
                      if (!preflightReady) {
                        return;
                      }
                      FirebaseCrashlytics.instance.log('tracking_toggle_start');
                      await TrackingServices.instance.start();
                      if (mounted && !TrackingServices.instance.isFallback) {
                        _checkBatteryOptimizations(context);
                      }
                    } on PlatformException catch (error) {
                      final providerState =
                          await TrackingServices.instance.getProviderState();
                      final isPermissionError =
                          providerState.status ==
                              TrackingAuthorizationStatus.denied ||
                          providerState.status ==
                              TrackingAuthorizationStatus.restricted;
                      if (!mounted) return;
                      messengerKey.currentState?.showSnackBar(
                        SnackBar(
                          content: Text(error.message ?? error.code),
                          duration: const Duration(seconds: 4),
                          action:
                              isPermissionError
                                  ? SnackBarAction(
                                    label:
                                        AppLocalizations.of(
                                          context,
                                        )!.settingsTitle,
                                    onPressed:
                                        () => AppSettings.openAppSettings(
                                          type: AppSettingsType.settings,
                                        ),
                                  )
                                  : null,
                        ),
                      );
                    } catch (error) {
                      if (!mounted) return;
                      messengerKey.currentState?.showSnackBar(
                        SnackBar(content: Text(error.toString())),
                      );
                    }
                  } else {
                    FirebaseCrashlytics.instance.log('tracking_toggle_stop');
                    await TrackingServices.instance.stop();
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            OverflowBar(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    try {
                      await TrackingServices.instance.getCurrentPosition(
                        extras: const {'manual': true},
                      );
                    } catch (error) {
                      final message =
                          error is PlatformException
                              ? (error.message ?? error.code)
                              : error.toString();
                      messengerKey.currentState?.showSnackBar(
                        SnackBar(content: Text(message)),
                      );
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.locationButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.settingsTitle),
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.urlLabel),
              subtitle: Text(
                Preferences.instance.getString(Preferences.url) ?? '',
              ),
            ),
            const SizedBox(height: 8),
            OverflowBar(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    if (await PasswordService.authenticate(context) &&
                        mounted) {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                      setState(() {});
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.settingsButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Traccar Client')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildTrackingCard(),
            const SizedBox(height: 16),
            _buildSettingsCard(),
          ],
        ),
      ),
    );
  }
}
