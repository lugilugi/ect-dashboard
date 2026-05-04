import 'package:geolocator/geolocator.dart';

import 'package:telemetry_dashboard/models/telemetry/phone_gps_sample.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

typedef PhoneFallbackSampleCallback = void Function(PhoneGpsSample sample);

class GpsSourceManager {
  final DashboardState _state;
  final PhoneFallbackSampleCallback? _onPhoneFallbackSample;

  GpsSourceManager(
    this._state, {
    PhoneFallbackSampleCallback? onPhoneFallbackSample,
  }) : _onPhoneFallbackSample = onPhoneFallbackSample;

  bool get prefersPhoneFallback => _state.isExternalGpsStale;

  void ingestExternalSample({
    required int satellites,
    required bool locked,
    required double lat,
    required double lon,
    required double headingDeg,
    required double speedKmh,
    required DateTime timestampUtc,
    String source = 'external_gps',
  }) {
    _state.updateExternalGpsStatus(satellites: satellites, locked: locked);

    if (!locked) {
      return;
    }

    _state.processGpsSample(
      lat: lat,
      lon: lon,
      headingDeg: headingDeg,
      speedKmh: speedKmh,
      timestampUtc: timestampUtc,
      source: source,
    );
  }

  void markExternalHeartbeat() {
    _state.markExternalGpsHeartbeat();
  }

  void ingestPhoneSample(Position position) {
    ingestPhoneSampleData(
      PhoneGpsSample(
        latitude: position.latitude,
        longitude: position.longitude,
        headingDeg: position.heading,
        speedMps: position.speed,
        accuracyM: position.accuracy,
        timestampUtc: position.timestamp.toUtc(),
      ),
    );
  }

  void ingestPhoneSampleData(PhoneGpsSample sample) {
    if (!prefersPhoneFallback) {
      return;
    }

    _state.updatePhoneGpsFallback(
      locked: sample.locked,
      accuracyM: sample.accuracyM,
    );

    if (!sample.locked) {
      _onPhoneFallbackSample?.call(sample);
      return;
    }

    final heading = sample.headingDeg.isNaN ? 0.0 : sample.headingDeg;
    final timestampUtc = sample.timestampUtc.toUtc();

    _state.processGpsSample(
      lat: sample.latitude,
      lon: sample.longitude,
      headingDeg: heading,
      speedKmh: sample.speedKmh,
      timestampUtc: timestampUtc,
      source: 'phone_gps',
    );

    _onPhoneFallbackSample?.call(sample);
  }
}
