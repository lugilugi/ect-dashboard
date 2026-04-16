import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/dashboard_state.dart';
import 'gps_source_manager.dart';

class PhoneGpsFallbackService {
  final DashboardState state;
  final GpsSourceManager gpsSourceManager;
  StreamSubscription<Position>? _positionSub;
  Timer? _staleCheckTimer;
  Position? _latestPosition;
  bool _started = false;

  PhoneGpsFallbackService(this.state, this.gpsSourceManager);

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

    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 200),
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
            _latestPosition = position;
            _pushFallbackIfNeeded(position);
          },
          onError: (Object e) {
            debugPrint('Phone GPS stream error: $e');
          },
        );

    _staleCheckTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!state.isExternalGpsStale) {
        return;
      }
      final cached = _latestPosition;
      if (cached != null) {
        _pushFallbackIfNeeded(cached);
      }
    });
  }

  void stop() {
    _staleCheckTimer?.cancel();
    _staleCheckTimer = null;
    _positionSub?.cancel();
    _positionSub = null;
    _latestPosition = null;
    _started = false;
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

  void _pushFallbackIfNeeded(Position position) {
    if (!state.isExternalGpsStale) {
      return;
    }

    gpsSourceManager.ingestPhoneSample(position);
  }
}
