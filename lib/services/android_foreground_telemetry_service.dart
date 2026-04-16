import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidForegroundTelemetryService {
  static const MethodChannel _channel =
      MethodChannel('ect_dashboard/foreground_telemetry');

  bool get _isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> start({required String title, required String text}) async {
    if (!_isSupported) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('startForegroundTelemetry', {
        'title': title,
        'text': text,
      });
    } on PlatformException catch (e) {
      debugPrint('Failed to start foreground telemetry service: ${e.message}');
    }
  }

  Future<void> stop() async {
    if (!_isSupported) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('stopForegroundTelemetry');
    } on PlatformException catch (e) {
      debugPrint('Failed to stop foreground telemetry service: ${e.message}');
    }
  }
}
