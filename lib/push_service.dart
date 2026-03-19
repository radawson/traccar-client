import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:traccar_client/password_service.dart';
import 'package:traccar_client/tracking_services.dart';
import 'package:traccar_client/transport_log_service.dart';

import 'preferences.dart';

enum CommandTransportType { none, websocket, fcm }

enum CommandTransportMode { auto, websocketOnly, fcmOnly, disabled }

class CommandDiagnostics {
  final CommandTransportType activeTransport;
  final CommandTransportMode configuredMode;
  final bool websocketEnabled;
  final bool websocketConfigured;
  final bool websocketConnected;
  final bool fcmEnabled;
  final bool fcmAvailable;
  final DateTime? lastCommandAt;
  final String? lastReconnectReason;
  final String? lastError;

  const CommandDiagnostics({
    required this.activeTransport,
    required this.configuredMode,
    required this.websocketEnabled,
    required this.websocketConfigured,
    required this.websocketConnected,
    required this.fcmEnabled,
    required this.fcmAvailable,
    this.lastCommandAt,
    this.lastReconnectReason,
    this.lastError,
  });

  CommandDiagnostics copyWith({
    CommandTransportType? activeTransport,
    CommandTransportMode? configuredMode,
    bool? websocketEnabled,
    bool? websocketConfigured,
    bool? websocketConnected,
    bool? fcmEnabled,
    bool? fcmAvailable,
    DateTime? lastCommandAt,
    String? lastReconnectReason,
    String? lastError,
    bool clearError = false,
    bool clearReconnectReason = false,
  }) {
    return CommandDiagnostics(
      activeTransport: activeTransport ?? this.activeTransport,
      configuredMode: configuredMode ?? this.configuredMode,
      websocketEnabled: websocketEnabled ?? this.websocketEnabled,
      websocketConfigured: websocketConfigured ?? this.websocketConfigured,
      websocketConnected: websocketConnected ?? this.websocketConnected,
      fcmEnabled: fcmEnabled ?? this.fcmEnabled,
      fcmAvailable: fcmAvailable ?? this.fcmAvailable,
      lastCommandAt: lastCommandAt ?? this.lastCommandAt,
      lastReconnectReason:
          clearReconnectReason
              ? null
              : (lastReconnectReason ?? this.lastReconnectReason),
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

class RemoteCommand {
  final String command;
  final String source;
  final String? commandId;
  final Map<String, dynamic> payload;

  const RemoteCommand({
    required this.command,
    required this.source,
    this.commandId,
    this.payload = const {},
  });
}

typedef RemoteCommandHandler = Future<void> Function(RemoteCommand command);

abstract class CommandTransport {
  String get name;
  Future<void> init(RemoteCommandHandler handler);
  Future<void> dispose();
}

class PushService {
  static CommandTransport? _websocketTransport;
  static CommandTransport? _fcmTransport;
  static CommandTransportMode _mode = CommandTransportMode.auto;
  static bool _useFcmFallback = true;

  static final ValueNotifier<CommandDiagnostics> diagnostics = ValueNotifier(
    const CommandDiagnostics(
      activeTransport: CommandTransportType.none,
      configuredMode: CommandTransportMode.auto,
      websocketEnabled: true,
      websocketConfigured: false,
      websocketConnected: false,
      fcmEnabled: false,
      fcmAvailable: false,
    ),
  );

  static String? get activeTransportName => switch (diagnostics
      .value
      .activeTransport) {
    CommandTransportType.websocket => 'websocket',
    CommandTransportType.fcm => 'fcm',
    CommandTransportType.none => 'none',
  };

  static String get configuredModeName => switch (_mode) {
    CommandTransportMode.auto => Preferences.commandTransportAuto,
    CommandTransportMode.websocketOnly =>
      Preferences.commandTransportWebsocketOnly,
    CommandTransportMode.fcmOnly => Preferences.commandTransportFcmOnly,
    CommandTransportMode.disabled => Preferences.commandTransportDisabled,
  };

  static String? get availabilityMessage {
    final state = diagnostics.value;
    if (_mode == CommandTransportMode.disabled) {
      return 'Remote commands are disabled by transport mode.';
    }
    if (_mode == CommandTransportMode.fcmOnly &&
        Platform.isAndroid &&
        !TrackingServices.playServicesAvailable) {
      return 'FCM-only mode requires Play Services on Android; no command transport is currently available.';
    }
    if (state.activeTransport == CommandTransportType.none) {
      if (Platform.isAndroid && !TrackingServices.playServicesAvailable) {
        return 'Play Services are unavailable. Configure WebSocket to keep remote commands working on GrapheneOS no-Play profiles.';
      }
      if (!state.websocketConfigured && !state.fcmAvailable) {
        return 'No command transport is available. Configure WebSocket URL or enable FCM fallback.';
      }
    }
    if (state.activeTransport == CommandTransportType.websocket &&
        Platform.isAndroid &&
        !TrackingServices.playServicesAvailable) {
      return 'Running in WebSocket command mode because Play Services are unavailable.';
    }
    return null;
  }

  static Future<void> init() async {
    await dispose();

    _mode = _parseMode(
      Preferences.instance.getString(Preferences.commandTransportMode),
    );
    final wsUrl =
        Preferences.instance.getString(Preferences.websocketUrl) ?? '';
    final wsEnabled =
        Preferences.instance.getBool(Preferences.websocketEnabled) ?? true;
    final wsConfigured = wsEnabled && wsUrl.trim().isNotEmpty;
    _useFcmFallback =
        Preferences.instance.getBool(Preferences.useFcmFallback) ?? true;

    diagnostics.value = diagnostics.value.copyWith(
      configuredMode: _mode,
      websocketEnabled: wsEnabled,
      websocketConfigured: wsConfigured,
      fcmEnabled: _isFcmAllowedForMode(_mode, _useFcmFallback),
      fcmAvailable: false,
      websocketConnected: false,
      activeTransport: CommandTransportType.none,
      clearError: true,
      clearReconnectReason: true,
    );

    if (_isWebSocketAllowedForMode(_mode) && wsConfigured) {
      _websocketTransport = WebSocketCommandTransport(
        url: wsUrl,
        token: Preferences.instance.getString(Preferences.websocketToken),
      );
      await _websocketTransport!.init(_executeCommand);
    } else if (!wsEnabled) {
      _recordReconnectReason('websocket_disabled');
    } else if (wsUrl.trim().isEmpty) {
      _recordReconnectReason('websocket_not_configured');
    }

    if (_isFcmAllowedForMode(_mode, _useFcmFallback)) {
      final fcmSupported =
          Platform.isIOS || TrackingServices.playServicesAvailable;
      if (fcmSupported) {
        try {
          _fcmTransport = FcmCommandTransport();
          await _fcmTransport!.init(_executeCommand);
          onFcmAvailabilityChanged(true);
        } catch (error) {
          onFcmAvailabilityChanged(false);
          _recordError(error);
        }
      } else {
        _recordReconnectReason('play_services_unavailable_for_fcm');
        TransportLogService.event(
          'command_transport_fcm_unavailable',
          context: {
            'mode': configuredModeName,
            'playServicesAvailable': TrackingServices.playServicesAvailable,
            'websocketConfigured': wsConfigured,
          },
        );
      }
    }
    _applyTransportSelection('init_complete');
  }

  static Future<void> dispose() async {
    final ws = _websocketTransport;
    _websocketTransport = null;
    if (ws != null) {
      await ws.dispose();
    }
    final fcm = _fcmTransport;
    _fcmTransport = null;
    if (fcm != null) {
      await fcm.dispose();
    }
  }

  static CommandTransportMode _parseMode(String? value) {
    return switch (value) {
      Preferences.commandTransportWebsocketOnly =>
        CommandTransportMode.websocketOnly,
      Preferences.commandTransportFcmOnly => CommandTransportMode.fcmOnly,
      Preferences.commandTransportDisabled => CommandTransportMode.disabled,
      _ => CommandTransportMode.auto,
    };
  }

  static bool _isWebSocketAllowedForMode(CommandTransportMode mode) {
    return mode != CommandTransportMode.disabled &&
        mode != CommandTransportMode.fcmOnly;
  }

  static bool _isFcmAllowedForMode(
    CommandTransportMode mode,
    bool useFallback,
  ) {
    if (mode == CommandTransportMode.disabled ||
        mode == CommandTransportMode.websocketOnly) {
      return false;
    }
    if (mode == CommandTransportMode.fcmOnly) {
      return true;
    }
    return useFallback;
  }

  static void _applyTransportSelection(String reason) {
    final selected = switch (_mode) {
      CommandTransportMode.disabled => CommandTransportType.none,
      CommandTransportMode.websocketOnly =>
        diagnostics.value.websocketConnected
            ? CommandTransportType.websocket
            : CommandTransportType.none,
      CommandTransportMode.fcmOnly =>
        diagnostics.value.fcmAvailable
            ? CommandTransportType.fcm
            : CommandTransportType.none,
      CommandTransportMode.auto =>
        Platform.isIOS
            ? (diagnostics.value.fcmAvailable
                ? CommandTransportType.fcm
                : (diagnostics.value.websocketConnected
                    ? CommandTransportType.websocket
                    : CommandTransportType.none))
            : (diagnostics.value.websocketConnected
                ? CommandTransportType.websocket
                : (diagnostics.value.fcmAvailable
                    ? CommandTransportType.fcm
                    : CommandTransportType.none)),
    };
    _setTransport(selected);
    _recordReconnectReason('selection_$reason');
    _emitAvailabilityDiagnostics(reason);
  }

  static void onWebSocketStateChanged({
    required bool connected,
    String? reconnectReason,
    String? error,
  }) {
    diagnostics.value = diagnostics.value.copyWith(
      websocketConnected: connected,
      lastReconnectReason: reconnectReason,
      lastError: error,
    );
    _applyTransportSelection('websocket_state_change');
  }

  static void onFcmAvailabilityChanged(bool available) {
    diagnostics.value = diagnostics.value.copyWith(fcmAvailable: available);
    _applyTransportSelection('fcm_state_change');
  }

  static void _setTransport(CommandTransportType type) {
    diagnostics.value = diagnostics.value.copyWith(activeTransport: type);
    TrackingServices.activeCommandTransport = switch (type) {
      CommandTransportType.websocket => 'websocket',
      CommandTransportType.fcm => 'fcm',
      CommandTransportType.none => 'none',
    };
  }

  static void _recordReconnectReason(String value) {
    diagnostics.value = diagnostics.value.copyWith(lastReconnectReason: value);
  }

  static void _recordError(Object error) {
    final message = error.toString();
    diagnostics.value = diagnostics.value.copyWith(lastError: message);
    TransportLogService.error('command_error', error);
  }

  static void _emitAvailabilityDiagnostics(String reason) {
    final message = availabilityMessage;
    if (message != null) {
      TransportLogService.event(
        'command_transport_notice',
        context: {
          'reason': reason,
          'message': message,
          'mode': configuredModeName,
          'activeTransport': activeTransportName ?? 'none',
        },
      );
    }
  }

  static Future<void> _executeCommand(RemoteCommand command) async {
    TransportLogService.event(
      'command_execute_start',
      context: {
        'source': command.source,
        'command': command.command,
        'commandId': command.commandId,
      },
    );
    diagnostics.value = diagnostics.value.copyWith(
      lastCommandAt: DateTime.now(),
    );

    switch (command.command) {
      case 'positionSingle':
        try {
          await TrackingServices.instance.getCurrentPosition(
            extras: {'remote': true, ...command.payload},
          );
        } catch (error) {
          TransportLogService.error(
            'command_position_single_failed',
            error,
            context: {'source': command.source, 'commandId': command.commandId},
          );
          rethrow;
        }
        TransportLogService.event(
          'command_execute_success',
          context: {
            'source': command.source,
            'command': command.command,
            'commandId': command.commandId,
          },
        );
        return;
      case 'positionPeriodic':
        await TrackingServices.instance.start();
        TransportLogService.event(
          'command_execute_success',
          context: {
            'source': command.source,
            'command': command.command,
            'commandId': command.commandId,
          },
        );
        return;
      case 'positionStop':
        await TrackingServices.instance.stop();
        TransportLogService.event(
          'command_execute_success',
          context: {
            'source': command.source,
            'command': command.command,
            'commandId': command.commandId,
          },
        );
        return;
      case 'factoryReset':
        await PasswordService.setPassword('');
        TransportLogService.event(
          'command_execute_success',
          context: {
            'source': command.source,
            'command': command.command,
            'commandId': command.commandId,
          },
        );
        return;
      default:
        TransportLogService.event(
          'command_execute_unknown',
          context: {
            'source': command.source,
            'command': command.command,
            'commandId': command.commandId,
          },
        );
        throw UnsupportedError('Unknown command: ${command.command}');
    }
  }

  static Future<void> _uploadToken(String? token) async {
    if (token == null) return;
    final id = Preferences.instance.getString(Preferences.id);
    final url = Preferences.instance.getString(Preferences.url);
    if (id == null || url == null) return;
    try {
      final request = await HttpClient().postUrl(Uri.parse(url));
      request.headers.contentType = ContentType.parse(
        'application/x-www-form-urlencoded',
      );
      request.write(
        'id=${Uri.encodeComponent(id)}&notificationToken=${Uri.encodeComponent(token)}',
      );
      await request.close();
    } catch (error) {
      TransportLogService.error('notification_token_upload_failed', error);
      _recordError(error);
    }
  }

  static Future<WebSocketProbeResult> probeWebSocket() async {
    final wsEnabled =
        Preferences.instance.getBool(Preferences.websocketEnabled) ?? true;
    if (!wsEnabled) {
      return const WebSocketProbeResult(
        success: false,
        code: 'websocket_disabled',
        message: 'WebSocket transport is disabled in Advanced settings.',
      );
    }
    final url = Preferences.instance.getString(Preferences.websocketUrl) ?? '';
    if (url.trim().isEmpty) {
      return const WebSocketProbeResult(
        success: false,
        code: 'websocket_not_configured',
        message: 'WebSocket URL is not configured.',
      );
    }
    final token =
        Preferences.instance.getString(Preferences.websocketToken) ?? '';
    final deviceId = Preferences.instance.getString(Preferences.id) ?? '';
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(url).timeout(const Duration(seconds: 8));
      socket.add(
        jsonEncode({
          'type': 'auth',
          'protocol': 'traccar-client-command-v1',
          'deviceId': deviceId,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'auth': {'token': token},
        }),
      );

      dynamic response;
      try {
        response = await socket.first.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        return const WebSocketProbeResult(
          success: true,
          code: 'connected_no_auth_response',
          message: 'Connected to WebSocket endpoint.',
        );
      }

      if (response is String) {
        final parsed = jsonDecode(response);
        if (parsed is Map && parsed['type'] == 'auth_error') {
          return WebSocketProbeResult(
            success: false,
            code: parsed['code']?.toString() ?? 'auth_error',
            message:
                parsed['message']?.toString() ?? 'WebSocket auth rejected.',
          );
        }
      }
      return const WebSocketProbeResult(
        success: true,
        code: 'ok',
        message: 'WebSocket connection and handshake succeeded.',
      );
    } catch (error) {
      return WebSocketProbeResult(
        success: false,
        code: 'connect_failed',
        message: error.toString(),
      );
    } finally {
      await socket?.close();
    }
  }
}

class WebSocketProbeResult {
  final bool success;
  final String code;
  final String message;

  const WebSocketProbeResult({
    required this.success,
    required this.code,
    required this.message,
  });
}

class FcmCommandTransport implements CommandTransport {
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  RemoteCommandHandler? _handler;

  @override
  String get name => 'fcm';

  @override
  Future<void> init(RemoteCommandHandler handler) async {
    _handler = handler;
    await FirebaseMessaging.instance.requestPermission();
    FirebaseMessaging.onBackgroundMessage(pushServiceBackgroundHandler);
    _messageSubscription = FirebaseMessaging.onMessage.listen(_onMessage);
    _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
        .listen(PushService._uploadToken);
    try {
      PushService._uploadToken(await FirebaseMessaging.instance.getToken());
    } catch (error) {
      TransportLogService.error('notification_token_fetch_failed', error);
      PushService._recordError(error);
    }
    PushService._setTransport(
      PushService.diagnostics.value.websocketConnected
          ? CommandTransportType.websocket
          : CommandTransportType.fcm,
    );
  }

  Future<void> _onMessage(RemoteMessage message) async {
    final command = message.data['command']?.toString();
    if (command == null || command.isEmpty || _handler == null) return;
    TransportLogService.event(
      'command_received',
      context: {
        'source': 'fcm',
        'command': command,
        'commandId': message.messageId,
      },
    );
    try {
      await _handler!(
        RemoteCommand(
          command: command,
          source: 'fcm',
          commandId: message.messageId,
        ),
      );
    } catch (error) {
      TransportLogService.error(
        'command_receive_failed',
        error,
        context: {
          'source': 'fcm',
          'command': command,
          'commandId': message.messageId,
        },
      );
      PushService._recordError(error);
    }
  }

  @override
  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();
    await _messageSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _messageSubscription = null;
    _handler = null;
  }
}

class WebSocketCommandTransport implements CommandTransport {
  final String url;
  final String? token;

  RemoteCommandHandler? _handler;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  int _reconnectAttempt = 0;

  final Queue<String> _seenCommandQueue = Queue<String>();
  final Set<String> _seenCommandSet = <String>{};

  WebSocketCommandTransport({required this.url, this.token});

  @override
  String get name => 'websocket';

  @override
  Future<void> init(RemoteCommandHandler handler) async {
    _handler = handler;
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    try {
      final socket = await WebSocket.connect(url);
      _socket = socket;
      _reconnectAttempt = 0;
      PushService.onWebSocketStateChanged(
        connected: true,
        reconnectReason: null,
        error: null,
      );
      _startPing();
      _sendAuth();
      _socketSubscription = socket.listen(
        _onData,
        onDone: () {
          _handleDisconnect('socket_closed');
        },
        onError: (error) {
          _handleDisconnect('socket_error', error: error);
        },
        cancelOnError: true,
      );
    } catch (error) {
      _handleDisconnect('connect_failed', error: error);
    }
  }

  void _sendAuth() {
    final id = Preferences.instance.getString(Preferences.id);
    if (id == null) return;
    _sendJson({
      'type': 'auth',
      'protocol': 'traccar-client-command-v1',
      'deviceId': id,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'auth': {'token': token ?? ''},
    });
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _sendJson({
        'type': 'ping',
        'protocol': 'traccar-client-command-v1',
        'deviceId': Preferences.instance.getString(Preferences.id),
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> _onData(dynamic event) async {
    try {
      final decoded = event is String ? jsonDecode(event) : event;
      if (decoded is! Map) return;
      final frame = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      final type = frame['type']?.toString();
      switch (type) {
        case 'auth_ok':
          PushService.onWebSocketStateChanged(
            connected: true,
            reconnectReason: null,
            error: null,
          );
          return;
        case 'auth_error':
          final code = frame['code']?.toString() ?? 'auth_error';
          _handleDisconnect('auth_error:$code');
          return;
        case 'ping':
          _sendJson({
            'type': 'pong',
            'protocol': 'traccar-client-command-v1',
            'deviceId': Preferences.instance.getString(Preferences.id),
            'timestamp': DateTime.now().toUtc().toIso8601String(),
          });
          return;
        case 'command':
          await _onCommand(frame);
          return;
      }
    } catch (error) {
      PushService._recordError(error);
    }
  }

  Future<void> _onCommand(Map<String, dynamic> frame) async {
    final command = frame['command']?.toString();
    if (command == null || command.isEmpty || _handler == null) return;
    final commandId = frame['commandId']?.toString();
    TransportLogService.event(
      'command_received',
      context: {
        'source': 'websocket',
        'command': command,
        'commandId': commandId,
      },
    );
    if (commandId != null && _alreadySeenCommand(commandId)) {
      TransportLogService.event(
        'command_duplicate_acked',
        context: {
          'source': 'websocket',
          'command': command,
          'commandId': commandId,
        },
      );
      _sendAck(commandId);
      return;
    }
    try {
      final payloadRaw = frame['payload'];
      final payload =
          payloadRaw is Map
              ? Map<String, dynamic>.from(payloadRaw.cast<String, dynamic>())
              : <String, dynamic>{};
      await _handler!(
        RemoteCommand(
          command: command,
          source: 'websocket',
          commandId: commandId,
          payload: payload,
        ),
      );
      if (commandId != null) {
        _rememberCommand(commandId);
        _sendAck(commandId);
      }
    } catch (error) {
      TransportLogService.error(
        'command_execute_failed',
        error,
        context: {
          'source': 'websocket',
          'command': command,
          'commandId': commandId,
        },
      );
      PushService._recordError(error);
      if (commandId != null) {
        _sendNack(commandId, 'execution_failed', error.toString());
      }
    }
  }

  bool _alreadySeenCommand(String commandId) =>
      _seenCommandSet.contains(commandId);

  void _rememberCommand(String commandId) {
    if (_seenCommandSet.contains(commandId)) return;
    _seenCommandSet.add(commandId);
    _seenCommandQueue.add(commandId);
    while (_seenCommandQueue.length > 100) {
      final removed = _seenCommandQueue.removeFirst();
      _seenCommandSet.remove(removed);
    }
  }

  void _sendAck(String commandId) {
    TransportLogService.event(
      'command_ack_sent',
      context: {'source': 'websocket', 'commandId': commandId},
    );
    _sendJson({
      'type': 'ack',
      'protocol': 'traccar-client-command-v1',
      'deviceId': Preferences.instance.getString(Preferences.id),
      'commandId': commandId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _sendNack(String commandId, String code, String message) {
    TransportLogService.event(
      'command_nack_sent',
      context: {'source': 'websocket', 'commandId': commandId, 'code': code},
    );
    _sendJson({
      'type': 'nack',
      'protocol': 'traccar-client-command-v1',
      'deviceId': Preferences.instance.getString(Preferences.id),
      'commandId': commandId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'error': {'code': code, 'message': message},
    });
  }

  void _sendJson(Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    socket.add(jsonEncode(payload));
  }

  void _handleDisconnect(String reason, {Object? error}) {
    if (_disposed) return;
    PushService.onWebSocketStateChanged(
      connected: false,
      reconnectReason: reason,
      error: error?.toString(),
    );
    _pingTimer?.cancel();
    _pingTimer = null;
    _scheduleReconnect(reason);
  }

  void _scheduleReconnect(String reason) {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt += 1;
    final exponent = _reconnectAttempt > 5 ? 5 : _reconnectAttempt;
    final baseSeconds = 1 << exponent;
    final cappedSeconds = baseSeconds > 60 ? 60 : baseSeconds;
    final jitterMillis =
        (cappedSeconds * 1000 * 0.2 * _reconnectAttempt / 10).round();
    _reconnectTimer = Timer(
      Duration(seconds: cappedSeconds, milliseconds: jitterMillis),
      _connect,
    );
    PushService._recordReconnectReason('reconnect_$reason');
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.close();
    _socket = null;
    _handler = null;
  }
}

@pragma('vm:entry-point')
Future<void> pushServiceBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await Preferences.init();
  await TrackingServices.initialize();
  final mode = PushService._parseMode(
    Preferences.instance.getString(Preferences.commandTransportMode),
  );
  final useFcmFallback =
      Preferences.instance.getBool(Preferences.useFcmFallback) ?? true;
  if (!PushService._isFcmAllowedForMode(mode, useFcmFallback)) return;
  final command = message.data['command']?.toString();
  if (command == null || command.isEmpty) return;
  TransportLogService.event(
    'push_background_handler',
    context: {'command': command, 'commandId': message.messageId},
  );
  await PushService._executeCommand(
    RemoteCommand(
      command: command,
      source: 'fcm_background',
      commandId: message.messageId,
    ),
  );
}
