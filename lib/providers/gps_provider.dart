import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class GpsState {
  final int gpsSatellites;
  final bool gpsLocked;
  final bool usingPhoneGpsFallback;
  final double? currentGpsLat;
  final double? currentGpsLon;
  final double? currentGpsHeadingDeg;
  final double? currentGpsSpeedKmh;
  final DateTime? currentGpsSampleAtUtc;
  final String? currentGpsSource;
  final bool notificationPermissionGranted;
  final bool backgroundLocationPermissionGranted;
  final int gpsSourceTransitions;
  final DateTime? lastGpsSourceChangedAtUtc;
  final double? phoneGpsAccuracyM;
  final DateTime lastExternalGpsMessageAt;

  const GpsState({
    this.gpsSatellites = 0,
    this.gpsLocked = false,
    this.usingPhoneGpsFallback = false,
    this.currentGpsLat,
    this.currentGpsLon,
    this.currentGpsHeadingDeg,
    this.currentGpsSpeedKmh,
    this.currentGpsSampleAtUtc,
    this.currentGpsSource,
    this.notificationPermissionGranted = true,
    this.backgroundLocationPermissionGranted = true,
    this.gpsSourceTransitions = 0,
    this.lastGpsSourceChangedAtUtc,
    this.phoneGpsAccuracyM,
    required this.lastExternalGpsMessageAt,
  });

  GpsState copyWith({
    int? gpsSatellites,
    bool? gpsLocked,
    bool? usingPhoneGpsFallback,
    double? currentGpsLat,
    double? currentGpsLon,
    double? currentGpsHeadingDeg,
    double? currentGpsSpeedKmh,
    DateTime? currentGpsSampleAtUtc,
    String? currentGpsSource,
    bool? notificationPermissionGranted,
    bool? backgroundLocationPermissionGranted,
    int? gpsSourceTransitions,
    DateTime? lastGpsSourceChangedAtUtc,
    double? phoneGpsAccuracyM,
    DateTime? lastExternalGpsMessageAt,
  }) {
    return GpsState(
      gpsSatellites: gpsSatellites ?? this.gpsSatellites,
      gpsLocked: gpsLocked ?? this.gpsLocked,
      usingPhoneGpsFallback: usingPhoneGpsFallback ?? this.usingPhoneGpsFallback,
      currentGpsLat: currentGpsLat ?? this.currentGpsLat,
      currentGpsLon: currentGpsLon ?? this.currentGpsLon,
      currentGpsHeadingDeg: currentGpsHeadingDeg ?? this.currentGpsHeadingDeg,
      currentGpsSpeedKmh: currentGpsSpeedKmh ?? this.currentGpsSpeedKmh,
      currentGpsSampleAtUtc: currentGpsSampleAtUtc ?? this.currentGpsSampleAtUtc,
      currentGpsSource: currentGpsSource ?? this.currentGpsSource,
      notificationPermissionGranted: notificationPermissionGranted ?? this.notificationPermissionGranted,
      backgroundLocationPermissionGranted: backgroundLocationPermissionGranted ?? this.backgroundLocationPermissionGranted,
      gpsSourceTransitions: gpsSourceTransitions ?? this.gpsSourceTransitions,
      lastGpsSourceChangedAtUtc: lastGpsSourceChangedAtUtc ?? this.lastGpsSourceChangedAtUtc,
      phoneGpsAccuracyM: phoneGpsAccuracyM ?? this.phoneGpsAccuracyM,
      lastExternalGpsMessageAt: lastExternalGpsMessageAt ?? this.lastExternalGpsMessageAt,
    );
  }
}

class GpsNotifier extends Notifier<GpsState> {
  @override
  GpsState build() {
    return GpsState(
      lastExternalGpsMessageAt: DateTime.now(),
    );
  }

  void updateState(GpsState newState) {
    state = newState;
  }
  
  void update({
    int? gpsSatellites,
    bool? gpsLocked,
    bool? usingPhoneGpsFallback,
    double? currentGpsLat,
    double? currentGpsLon,
    double? currentGpsHeadingDeg,
    double? currentGpsSpeedKmh,
    DateTime? currentGpsSampleAtUtc,
    String? currentGpsSource,
    bool? notificationPermissionGranted,
    bool? backgroundLocationPermissionGranted,
    int? gpsSourceTransitions,
    DateTime? lastGpsSourceChangedAtUtc,
    double? phoneGpsAccuracyM,
    DateTime? lastExternalGpsMessageAt,
  }) {
    state = state.copyWith(
      gpsSatellites: gpsSatellites,
      gpsLocked: gpsLocked,
      usingPhoneGpsFallback: usingPhoneGpsFallback,
      currentGpsLat: currentGpsLat,
      currentGpsLon: currentGpsLon,
      currentGpsHeadingDeg: currentGpsHeadingDeg,
      currentGpsSpeedKmh: currentGpsSpeedKmh,
      currentGpsSampleAtUtc: currentGpsSampleAtUtc,
      currentGpsSource: currentGpsSource,
      notificationPermissionGranted: notificationPermissionGranted,
      backgroundLocationPermissionGranted: backgroundLocationPermissionGranted,
      gpsSourceTransitions: gpsSourceTransitions,
      lastGpsSourceChangedAtUtc: lastGpsSourceChangedAtUtc,
      phoneGpsAccuracyM: phoneGpsAccuracyM,
      lastExternalGpsMessageAt: lastExternalGpsMessageAt,
    );
  }
}

final gpsProvider = NotifierProvider<GpsNotifier, GpsState>(GpsNotifier.new);
