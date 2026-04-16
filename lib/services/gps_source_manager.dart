import 'package:geolocator/geolocator.dart';

import '../providers/dashboard_state.dart';

class GpsSourceManager {
  final DashboardState _state;

  GpsSourceManager(this._state);

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
    if (!prefersPhoneFallback) {
      return;
    }

    final heading = position.heading.isNaN ? 0.0 : position.heading;
    final timestampUtc = position.timestamp.toUtc();

    _state.processGpsSample(
      lat: position.latitude,
      lon: position.longitude,
      headingDeg: heading,
      speedKmh: position.speed * 3.6,
      timestampUtc: timestampUtc,
      source: 'phone_gps',
    );

    _state.updatePhoneGpsFallback(
      locked: position.accuracy <= 50.0,
      accuracyM: position.accuracy,
    );
  }
}