
import 'tracking_services.dart';

@Deprecated('Use TrackingServices directly.')
class GeolocationService {
  static Future<void> init() => TrackingServices.initialize();
}
