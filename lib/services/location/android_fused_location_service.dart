import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:telemetry_dashboard/models/telemetry/phone_gps_sample.dart';

class AndroidFusedLocationService {
  static const EventChannel _channel = EventChannel(
    'ect_dashboard/fused_location',
  );

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Stream<PhoneGpsSample> get sampleStream async* {
    if (!isSupported) {
      return;
    }

    await for (final dynamic event in _channel.receiveBroadcastStream()) {
      final sample = _parseSample(event);
      if (sample != null) {
        yield sample;
      }
    }
  }

  PhoneGpsSample? _parseSample(dynamic event) {
    if (event is! Map<dynamic, dynamic>) {
      return null;
    }

    final available = event['available'];
    if (available is bool && !available) {
      return null;
    }

    final latitude = _asDouble(event['latitude']);
    final longitude = _asDouble(event['longitude']);
    final accuracyM = _asDouble(event['accuracyM']);
    if (latitude == null || longitude == null || accuracyM == null) {
      return null;
    }

    final speedMps = _asDouble(event['speedMps']) ?? 0.0;
    final headingDeg = _asDouble(event['headingDeg']) ?? 0.0;
    final satelliteCount = _asInt(event['satellites']) ?? -1;
    final timestampMs =
        _asInt(event['timestampMs']) ??
        DateTime.now().toUtc().millisecondsSinceEpoch;

    return PhoneGpsSample(
      latitude: latitude,
      longitude: longitude,
      headingDeg: headingDeg,
      speedMps: speedMps,
      accuracyM: accuracyM,
      timestampUtc: DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
        isUtc: true,
      ),
      satelliteCount: satelliteCount,
    );
  }

  double? _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }
}
