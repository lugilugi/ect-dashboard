import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:telemetry_dashboard/models/telemetry/phone_gps_sample.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/location/android_fused_location_service.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';

class PhoneGpsFallbackService {
  static const Duration _fallbackEmitInterval = Duration(milliseconds: 33);

  final DashboardState state;
  final GpsSourceManager gpsSourceManager;
  final AndroidFusedLocationService _androidFusedLocationService;

  StreamSubscription<PhoneGpsSample>? _androidFusedSubscription;
  StreamSubscription<Position>? _positionSub;
  Timer? _fallbackEmitTimer;
  PhoneGpsSample? _latestSample;
  bool _started = false;

  PhoneGpsFallbackService(
    this.state,
    this.gpsSourceManager, {
    AndroidFusedLocationService? androidFusedLocationService,
  }) : _androidFusedLocationService =
           androidFusedLocationService ?? AndroidFusedLocationService();

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;

    final ready = await _ensureLocationReady();
    if (!ready) {
      _started = false;
      debugPrint(
        'Phone GPS fallback disabled: location service unavailable or permission denied.',
      );
      return;
    }

    await _startLocationStream();

    _fallbackEmitTimer = Timer.periodic(_fallbackEmitInterval, (_) {
      final cached = _latestSample;
      if (cached == null) {
        return;
      }
      _pushFallbackIfNeeded(cached);
    });
  }

  void stop() {
    _fallbackEmitTimer?.cancel();
    _fallbackEmitTimer = null;
    _androidFusedSubscription?.cancel();
    _androidFusedSubscription = null;
    _positionSub?.cancel();
    _positionSub = null;
    _latestSample = null;
    _started = false;
  }

  Future<void> _startLocationStream() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final usingFused = _startAndroidFusedStream();
      if (usingFused) {
        return;
      }
    }
    _startGeolocatorStream();
  }

  bool _startAndroidFusedStream() {
    try {
      _androidFusedSubscription = _androidFusedLocationService.sampleStream
          .listen(
            (PhoneGpsSample sample) {
              _latestSample = sample;
              _pushFallbackIfNeeded(sample);
            },
            onError: (Object e) {
              debugPrint('Android fused location stream error: $e');
              if (_positionSub == null) {
                _startGeolocatorStream();
              }
            },
          );
      return true;
    } on MissingPluginException catch (e) {
      debugPrint('Android fused location plugin unavailable: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('Android fused location start failed: ${e.message}');
      return false;
    }
  }

  void _startGeolocatorStream() {
    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 100),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        distanceFilter: 0,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
    }

    _positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
          (Position position) {
            final sample = PhoneGpsSample(
              latitude: position.latitude,
              longitude: position.longitude,
              headingDeg: position.heading,
              speedMps: position.speed,
              accuracyM: position.accuracy,
              timestampUtc: position.timestamp.toUtc(),
            );
            _latestSample = sample;
            _pushFallbackIfNeeded(sample);
          },
          onError: (Object e) {
            debugPrint('Phone GPS stream error: $e');
          },
        );
  }

  Future<bool> _ensureLocationReady() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }

    await _ensureAndroidRuntimePermissions();

    return true;
  }

  Future<void> _ensureAndroidRuntimePermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    PermissionStatus notificationStatus = await Permission.notification.status;
    if (!notificationStatus.isGranted && !notificationStatus.isLimited) {
      notificationStatus = await Permission.notification.request();
      if (!notificationStatus.isGranted) {
        debugPrint(
          'Notification permission not granted; foreground telemetry notification may be suppressed.',
        );
      }
    }

    PermissionStatus backgroundLocationStatus =
        await Permission.locationAlways.status;
    if (!backgroundLocationStatus.isGranted) {
      backgroundLocationStatus = await Permission.locationAlways.request();
      if (!backgroundLocationStatus.isGranted) {
        debugPrint(
          'Background location permission not granted; phone GPS fallback may pause while app is backgrounded.',
        );
      }
    }

    state.updateGpsPermissionStatus(
      notificationGranted:
          notificationStatus.isGranted || notificationStatus.isLimited,
      backgroundLocationGranted: backgroundLocationStatus.isGranted,
    );
  }

  void _pushFallbackIfNeeded(PhoneGpsSample sample) {
    if (!state.isExternalGpsStale) {
      return;
    }

    gpsSourceManager.ingestPhoneSampleData(sample);
  }
}
