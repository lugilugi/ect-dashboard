import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:telemetry_dashboard/models/telemetry/phone_gps_sample.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';

Position _position({
  double lat = 14.0,
  double lon = 121.0,
  double heading = 5.0,
  double speedMs = 3.0,
  double accuracy = 4.0,
}) {
  return Position(
    latitude: lat,
    longitude: lon,
    timestamp: DateTime.now().toUtc(),
    accuracy: accuracy,
    altitude: 0.0,
    altitudeAccuracy: 1.0,
    heading: heading,
    headingAccuracy: 1.0,
    speed: speedMs,
    speedAccuracy: 0.1,
  );
}

PhoneGpsSample _sample({
  double lat = 14.0,
  double lon = 121.0,
  double headingDeg = 5.0,
  double speedMps = 3.0,
  double accuracyM = 4.0,
}) {
  return PhoneGpsSample(
    latitude: lat,
    longitude: lon,
    headingDeg: headingDeg,
    speedMps: speedMps,
    accuracyM: accuracyM,
    timestampUtc: DateTime.now().toUtc(),
  );
}

void main() {
  group('GpsSourceManager', () {
    test('ingestExternalSample updates external GPS status', () {
      final state = DashboardState();
      final manager = GpsSourceManager(state);

      manager.ingestExternalSample(
        satellites: 10,
        locked: true,
        lat: 14.566,
        lon: 120.994,
        headingDeg: 12.0,
        speedKmh: 32.0,
        timestampUtc: DateTime.now().toUtc(),
      );

      expect(state.gpsLocked, isTrue);
      expect(state.gpsSatellites, 10);
      expect(state.usingPhoneGpsFallback, isFalse);
      expect(state.gpsSourceText, 'EXT');

      state.dispose();
    });

    test('ignores phone sample while external GPS is fresh', () {
      final state = DashboardState();
      final manager = GpsSourceManager(state);

      manager.ingestPhoneSample(_position());

      expect(state.usingPhoneGpsFallback, isFalse);
      expect(state.phoneGpsAccuracyM, isNull);

      state.dispose();
    });

    test('uses phone fallback when external GPS is stale', () async {
      final state = DashboardState(
        externalGpsTimeout: const Duration(milliseconds: 1),
      );
      final manager = GpsSourceManager(state);

      await Future<void>.delayed(const Duration(milliseconds: 5));

      manager.ingestPhoneSample(
        _position(heading: 18.0, speedMs: 5.0, accuracy: 3.0),
      );

      expect(state.usingPhoneGpsFallback, isTrue);
      expect(state.gpsLocked, isTrue);
      expect(state.gpsSourceText, 'PHONE');
      expect(state.phoneGpsAccuracyM, 3.0);

      state.dispose();
    });

    test('forwards stale phone sample to fallback callback', () async {
      final state = DashboardState(
        externalGpsTimeout: const Duration(milliseconds: 1),
      );
      PhoneGpsSample? callbackSample;
      final manager = GpsSourceManager(
        state,
        onPhoneFallbackSample: (sample) {
          callbackSample = sample;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 5));

      manager.ingestPhoneSampleData(
        _sample(headingDeg: 21.0, speedMps: 6.0, accuracyM: 2.5),
      );

      expect(callbackSample, isNotNull);
      expect(callbackSample!.speedKmh, closeTo(21.6, 0.001));
      expect(callbackSample!.accuracyM, 2.5);

      state.dispose();
    });
  });
}
