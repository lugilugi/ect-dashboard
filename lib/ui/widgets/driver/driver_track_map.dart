import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';
import 'package:telemetry_dashboard/ui/widgets/common/map_markers.dart';
import 'package:telemetry_dashboard/ui/widgets/common/map_tiles.dart';

/// Driver-facing track map for the right panel of the efficiency grid.
/// Shows the recent GPS trace (ring buffer in DashboardState), the active
/// finish line, the pulsing car marker and the accuracy circle. Follows the
/// car north-up at a fixed zoom; gestures are disabled so the driver cannot
/// lose the auto-follow.
class DriverTrackMap extends StatefulWidget {
  final DashboardState state;
  final Palette p;

  const DriverTrackMap({super.key, required this.state, required this.p});

  @override
  State<DriverTrackMap> createState() => _DriverTrackMapState();
}

class _DriverTrackMapState extends State<DriverTrackMap> {
  static const double _followZoom = 17.0;
  static const double _followMinStepM = 5.0;

  final MapController _mapController = MapController();
  LatLng? _lastFollowed;

  @override
  void initState() {
    super.initState();
    _lastFollowed = _initialCenter();
  }

  LatLng _initialCenter() {
    final state = widget.state;
    if (state.hasCurrentGpsSample) {
      return LatLng(state.currentGpsLat!, state.currentGpsLon!);
    }
    final lastLat = state.lastKnownLat;
    final lastLon = state.lastKnownLon;
    if (lastLat != null && lastLon != null) {
      return LatLng(lastLat, lastLon);
    }
    return const LatLng(14.5660, 120.9920);
  }

  @override
  void didUpdateWidget(covariant DriverTrackMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final state = widget.state;
    if (!state.hasCurrentGpsSample) {
      return;
    }
    final target = LatLng(state.currentGpsLat!, state.currentGpsLon!);
    final last = _lastFollowed;
    if (last == null ||
        _distanceMeters(last.latitude, last.longitude,
                target.latitude, target.longitude) >=
            _followMinStepM) {
      _lastFollowed = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _mapController.move(target, _followZoom);
        }
      });
    }
  }

  double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusM = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = dLat * dLat +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * dLon * dLon;
    return earthRadiusM * sqrt(a);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final p = widget.p;

    final trackPoints = [
      for (final point in state.gpsTrackPoints)
        LatLng(point.lat, point.lon),
    ];

    return ClipRect(
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _lastFollowed ?? _initialCenter(),
              initialZoom: _followZoom,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.none,
              ),
            ),
            children: [
              RoadMapTileLayer(useLightTheme: state.useLightTheme),
              if (state.hasCurrentGpsSample)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(
                        state.currentGpsLat!,
                        state.currentGpsLon!,
                      ),
                      radius: state.phoneGpsAccuracyM ?? 10.0,
                      useRadiusInMeter: true,
                      color: p.cyan.withValues(alpha: 0.12),
                      borderColor: p.cyan.withValues(alpha: 0.4),
                      borderStrokeWidth: 1.5,
                    ),
                  ],
                ),
              if (trackPoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: trackPoints,
                      strokeWidth: 4.0,
                      color: p.cyan,
                      borderColor: Colors.white.withValues(alpha: 0.8),
                      borderStrokeWidth: 1.0,
                    ),
                  ],
                ),
              if (state.lapBoundaryConfigured)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        LatLng(
                          state.lapBoundaryStart.lat,
                          state.lapBoundaryStart.lon,
                        ),
                        LatLng(
                          state.lapBoundaryEnd.lat,
                          state.lapBoundaryEnd.lon,
                        ),
                      ],
                      strokeWidth: 7.0,
                      color: p.amber,
                      borderColor: Colors.black.withValues(alpha: 0.65),
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (state.hasCurrentGpsSample)
                    Marker(
                      point: LatLng(
                        state.currentGpsLat!,
                        state.currentGpsLon!,
                      ),
                      width: 28,
                      height: 28,
                      child: PulsingUserLocationMarker(color: p.cyan),
                    ),
                ],
              ),
            ],
          ),
          if (!state.hasCurrentGpsSample)
            trackPoints.isEmpty
                ? const _WaitingForGpsOverlay()
                : _GpsLostBanner(),
        ],
      ),
    );
  }
}

class _WaitingForGpsOverlay extends StatelessWidget {
  const _WaitingForGpsOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.7),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.cyan,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'WAITING FOR GPS FIX...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GpsLostBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 6,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Colors.amber.withValues(alpha: 0.6),
            ),
          ),
          child: const Text(
            'GPS LOST — TRACK HISTORY',
            style: TextStyle(
              color: Colors.amber,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
