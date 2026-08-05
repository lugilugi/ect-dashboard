import 'package:flutter/material.dart';

/// Pulsing current-location marker used by both the service-mode geofence
/// map (config_view.dart) and the driver track map (driver_track_map.dart).
class PulsingUserLocationMarker extends StatefulWidget {
  final Color? color;

  const PulsingUserLocationMarker({super.key, this.color});

  @override
  State<PulsingUserLocationMarker> createState() =>
      _PulsingUserLocationMarkerState();
}

class _PulsingUserLocationMarkerState extends State<PulsingUserLocationMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _color = widget.color ?? Colors.blue;
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant PulsingUserLocationMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _color = widget.color ?? Colors.blue;
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 24.0 * _pulseController.value,
              height: 24.0 * _pulseController.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _color
                    .withValues(alpha: 0.6 * (1.0 - _pulseController.value)),
              ),
            ),
            Container(
              width: 12.0,
              height: 12.0,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _color,
              ),
            ),
            Container(
              width: 14.0,
              height: 14.0,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ],
        );
      },
    );
  }
}
