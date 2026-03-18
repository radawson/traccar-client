class TrackingLocation {
  final String timestamp;
  final double latitude;
  final double longitude;
  final double heading;
  final bool isMoving;
  final Map<String, dynamic>? extras;

  const TrackingLocation({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.heading,
    required this.isMoving,
    this.extras,
  });
}

class TrackingState {
  final bool enabled;
  final bool isMoving;

  const TrackingState({
    required this.enabled,
    required this.isMoving,
  });
}

enum TrackingAuthorizationStatus {
  denied,
  restricted,
  authorized,
  unknown,
}

class TrackingProviderState {
  final TrackingAuthorizationStatus status;

  const TrackingProviderState(this.status);
}

typedef EnabledChangeCallback = void Function(bool enabled);
typedef MotionChangeCallback = void Function(TrackingLocation location);

abstract class TrackingService {
  bool get isFallback;
  bool get supportsPushCommands;

  Future<void> init();
  Future<void> start();
  Future<void> stop();
  Future<TrackingState> getState();
  Future<TrackingProviderState> getProviderState();
  Future<void> getCurrentPosition({Map<String, dynamic>? extras});
  Future<void> setConfig();
  void onEnabledChange(EnabledChangeCallback callback);
  void onMotionChange(MotionChangeCallback callback);
}
