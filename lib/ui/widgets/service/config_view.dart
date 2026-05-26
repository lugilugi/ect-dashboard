import 'dart:async';
import 'dart:math';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/services/orchestration/lap_boundary_service.dart';
import 'package:telemetry_dashboard/ui/widgets/common/painters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:telemetry_dashboard/providers/app_providers.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';
import 'package:telemetry_dashboard/models/telemetry/can_messages.dart';
enum ConfigSection {
  connectivity,
  canDictionary,
  throttle,
  session,
  alerts,
  storage,
  display,
}

class ConfigView extends ConsumerStatefulWidget {
  final Palette p;
  const ConfigView({super.key, required this.p});

  @override
  ConsumerState<ConfigView> createState() => ConfigViewState();
}

class ConfigViewState extends ConsumerState<ConfigView> with TickerProviderStateMixin {
  ConfigSection _selectedSection = ConfigSection.connectivity;
  final TextEditingController _canSearchController = TextEditingController();
  final MapController _geofenceMapController = MapController();
  final Distance _geoDistance = const Distance();
  String _canSearchQuery = '';
  bool _geofenceDraftInitialized = false;
  bool _isDrawingGeofence = false;
  LatLng? _draftGeofenceStart;
  LatLng? _draftGeofenceEnd;
  bool _dismissGpsWaitingOverlay = false;
  bool _hasCenteredOnGps = false;

  DashboardState get state => ref.read(dashboardStateProvider);
  Palette get p => widget.p;

  @override
  void dispose() {
    _canSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild config panel on state changes while keeping method bodies read-only.
    ref.watch(dashboardStateProvider);

    final width = MediaQuery.sizeOf(context).width;
    final railWidth = width < 980 ? 188.0 : 224.0;

    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: railWidth, child: _buildMenuRail()),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: KeyedSubtree(
                  key: ValueKey(_selectedSection),
                  child: _buildSelectedSection(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuRail() {
    final items = <({ConfigSection section, String label, IconData icon})>[
      (
        section: ConfigSection.connectivity,
        label: 'Connectivity',
        icon: Icons.usb_rounded,
      ),
      (
        section: ConfigSection.canDictionary,
        label: 'CAN Dictionary',
        icon: Icons.menu_book_rounded,
      ),
      (
        section: ConfigSection.throttle,
        label: 'Throttle',
        icon: Icons.timeline_rounded,
      ),
      (
        section: ConfigSection.session,
        label: 'Session Rules',
        icon: Icons.flag_rounded,
      ),
      (
        section: ConfigSection.alerts,
        label: 'Alerts',
        icon: Icons.notifications_active_rounded,
      ),
      (
        section: ConfigSection.storage,
        label: 'Storage',
        icon: Icons.sd_storage_rounded,
      ),
      (
        section: ConfigSection.display,
        label: 'Display/Drive',
        icon: Icons.tune_rounded,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.border, width: 1),
        color: p.light ? Colors.white : const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = _selectedSection == item.section;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                setState(() {
                  _selectedSection = item.section;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? p.cyan : p.border),
                  color: selected
                      ? p.cyan.withValues(alpha: 0.12)
                      : Colors.transparent,
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 16,
                      color: selected ? p.cyan : p.dimText,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.label,
                        style: TextStyle(
                          color: selected ? p.cyan : p.mainText,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedSection(BuildContext context) {
    switch (_selectedSection) {
      case ConfigSection.connectivity:
        return _buildConnectivitySection();
      case ConfigSection.canDictionary:
        return _buildCanDictionarySection();
      case ConfigSection.throttle:
        return _buildThrottleSection(context);
      case ConfigSection.session:
        return _buildSessionSection(context);
      case ConfigSection.alerts:
        return _buildAlertsSection();
      case ConfigSection.storage:
        return _buildStorageSection();
      case ConfigSection.display:
        return _buildDisplaySection();
    }
  }

  Widget _buildConnectivitySection() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Connectivity Status',
            subtitle: 'Quick health snapshot for telemetry links.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _infoRow('BAUD RATE', '500000'),
                _infoRow(
                  'CAN IDs',
                  '${state.lastCanPayloads.length} active',
                  valueColor: state.lastCanPayloads.isEmpty ? p.red : p.green,
                ),
                _infoRow(
                  'USB',
                  state.isConnected ? 'CONNECTED' : 'DISCONNECTED',
                  valueColor: state.isConnected
                      ? p.green
                      : (p.light ? Colors.grey.shade500 : p.amber),
                ),
                _infoRow(
                  'SIM',
                  state.isSimulated ? 'ACTIVE' : 'OFF',
                  valueColor: state.isSimulated ? p.amber : p.dimText,
                ),
                _infoRow(
                  'MQTT',
                  state.isServerConnected ? 'ONLINE' : 'OFFLINE',
                  valueColor: state.isServerConnected ? p.cyan : p.red,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _buildCmdBtn('RESET CAN LOGS', () {
            setState(() {
              state.lastCanPayloads.clear();
            });
          }),
        ],
      ),
    );
  }

  Widget _buildCanDictionarySection() {
    final query = _canSearchQuery.trim().toLowerCase();
    final filteredEntries = CanDictionary.entries
        .where((entry) {
          if (query.isEmpty) {
            return true;
          }
          final haystack =
              '${entry.hexId} ${entry.key} ${entry.label} ${entry.direction} ${entry.decodeNotes}'
                  .toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'CAN Dictionary',
            subtitle: 'Reference of decoded CAN IDs and payload meanings.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _canSearchController,
                  style: TextStyle(color: p.mainText, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Search by ID/name',
                    labelStyle: TextStyle(color: p.dimText),
                    prefixIcon: Icon(Icons.search_rounded, color: p.dimText),
                    suffixIcon: _canSearchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear_rounded, color: p.dimText),
                            onPressed: () {
                              _canSearchController.clear();
                              setState(() {
                                _canSearchQuery = '';
                              });
                            },
                          ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _canSearchQuery = value;
                    });
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  'MATCHES: ${filteredEntries.length}',
                  style: TextStyle(
                    color: p.dimText,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 380),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.border),
                    color: p.light
                        ? Colors.grey.shade100
                        : const Color(0xFF101010),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: filteredEntries.isEmpty
                      ? Center(
                          child: Text(
                            'No dictionary entries match your search.',
                            style: TextStyle(color: p.dimText, fontSize: 11),
                          ),
                        )
                      : ListView.separated(
                          itemCount: filteredEntries.length,
                          separatorBuilder: (context, index) =>
                              Divider(color: p.border, height: 12),
                          itemBuilder: (context, index) {
                            final entry = filteredEntries[index];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(color: p.border),
                                        color: p.light
                                            ? Colors.white
                                            : const Color(0xFF181818),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        entry.hexId,
                                        style: TextStyle(
                                          color: p.cyan,
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.label,
                                            style: TextStyle(
                                              color: p.mainText,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${entry.direction} | DLC ${entry.expectedDlc} | key: ${entry.key}',
                                            style: TextStyle(
                                              color: p.dimText,
                                              fontFamily: 'monospace',
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  entry.decodeNotes,
                                  style: TextStyle(
                                    color: p.dimText,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

Widget _buildGeofenceEditorCard(BuildContext context) {
    _ensureGeofenceDraftInitialized();

    final center = _resolveGeofenceMapCenter();
    final hasDraft = _draftGeofenceStart != null && _draftGeofenceEnd != null;
    final polylinePoints = <LatLng>[
      ?_draftGeofenceStart,
      ?_draftGeofenceEnd,
    ];

    // Smart Auto-Centering on GPS Lock
    final hasGps = state.gpsLocked && state.hasCurrentGpsSample;
    if (hasGps && !_hasCenteredOnGps) {
      _hasCenteredOnGps = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _animatedMapMove(
            LatLng(state.currentGpsLat!, state.currentGpsLon!),
            17.5,
          );
        }
      });
    } else if (!hasGps && _hasCenteredOnGps) {
      _hasCenteredOnGps = false;
    }

    return _settingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _configSwitch('DRAW MODE', _isDrawingGeofence, (val) {
                  setState(() {
                    _isDrawingGeofence = val;
                  });
                }),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _isDrawingGeofence
                ? 'Tap once for line START, tap again for line END. Further taps move nearest endpoint.'
                : 'Enable Draw Mode to place or edit line endpoints.',
            style: TextStyle(color: p.dimText, fontSize: 10),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isDrawingGeofence ? p.cyan : p.border,
                width: 2.0,
              ),
              boxShadow: [
                if (_isDrawingGeofence)
                  BoxShadow(
                    color: p.cyan.withValues(alpha: 0.25),
                    blurRadius: 8.0,
                    spreadRadius: 2.0,
                  ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 320,
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _geofenceMapController,
                      options: MapOptions(
                        initialCenter: center,
                        initialZoom: 17,
                        onTap: (_, point) => _handleGeofenceMapTap(point),
                        onPositionChanged: (position, hasGesture) {
                          setState(() {});
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: state.useLightTheme
                              ? 'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png'
                              : 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.telemetry_dashboard',
                          maxNativeZoom: 19,
                          maxZoom: 20,
                        ),
                        if (state.hasCurrentGpsSample)
                          CircleLayer(
                            circles: [
                              CircleMarker(
                                point: LatLng(state.currentGpsLat!, state.currentGpsLon!),
                                radius: state.phoneGpsAccuracyM ?? 10.0,
                                useRadiusInMeter: true,
                                color: p.cyan.withValues(alpha: 0.12),
                                borderColor: p.cyan.withValues(alpha: 0.4),
                                borderStrokeWidth: 1.5,
                              ),
                            ],
                          ),
                        if (polylinePoints.length == 2)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: polylinePoints,
                                strokeWidth: 4.0,
                                color: p.cyan,
                                borderColor: Colors.white.withValues(alpha: 0.8),
                                borderStrokeWidth: 1.0,
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            if (state.hasCurrentGpsSample)
                              Marker(
                                point: LatLng(state.currentGpsLat!, state.currentGpsLon!),
                                width: 28,
                                height: 28,
                                child: const _PulsingUserLocationMarker(),
                              ),
                            if (_draftGeofenceStart != null)
                              Marker(
                                point: _draftGeofenceStart!,
                                width: 26,
                                height: 26,
                                child: _buildGeofenceMarker('A', p.green),
                              ),
                            if (_draftGeofenceEnd != null)
                              Marker(
                                point: _draftGeofenceEnd!,
                                width: 26,
                                height: 26,
                                child: _buildGeofenceMarker('B', p.red),
                              ),
                          ],
                        ),
                      ],
                    ),
                    Positioned(
                      bottom: 10,
                      left: 10,
                      child: _buildScaleIndicator(),
                    ),
                    Positioned(
                      top: 10,
                      right: 10,
                      child: _buildMapFabStack(),
                    ),
                    _buildGpsWaitingOverlay(),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _infoRow('START', _formatLatLng(_draftGeofenceStart)),
          _infoRow('END', _formatLatLng(_draftGeofenceEnd)),
          _infoRow(
            'CURRENT GPS',
            _currentGpsText,
            valueColor: state.hasCurrentGpsSample
                ? (state.gpsLocked ? p.lightGreen : p.orange)
                : p.dimText,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final buttonWidth = (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: buttonWidth,
                    child: _buildCmdBtn('SNAP TO CURRENT GPS', () {
                      _snapDraftLineToCurrentGps(context);
                    }, compact: true),
                  ),
                  SizedBox(
                    width: buttonWidth,
                    child: _buildCmdBtn('RESET TO ACTIVE', () {
                      setState(() {
                        _geofenceDraftInitialized = false;
                        _isDrawingGeofence = false;
                        _dismissGpsWaitingOverlay = false;
                      });
                    }, compact: true),
                  ),
                  SizedBox(
                    width: buttonWidth,
                    child: _buildCmdBtn('CLEAR DRAFT', () {
                      setState(() {
                        _draftGeofenceStart = null;
                        _draftGeofenceEnd = null;
                        _dismissGpsWaitingOverlay = false;
                      });
                    }, compact: true),
                  ),
                  SizedBox(
                    width: buttonWidth,
                    child: _buildCmdBtn('APPLY LINE', () {
                      if (!hasDraft) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Place both START and END points before applying geofence.',
                            ),
                          ),
                        );
                        return;
                      }

                      state.configureLapBoundary(
                        start: GeoPoint(
                          lat: _draftGeofenceStart!.latitude,
                          lon: _draftGeofenceStart!.longitude,
                        ),
                        end: GeoPoint(
                          lat: _draftGeofenceEnd!.latitude,
                          lon: _draftGeofenceEnd!.longitude,
                        ),
                      );
                      setState(() {
                        _isDrawingGeofence = false;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Lap crossing geofence updated.'),
                        ),
                      );
                    }, compact: true),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGeofenceMarker(String label, Color color) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: p.bg, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: p.light ? Colors.white : Colors.black,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  void _handleGeofenceMapTap(LatLng point) {
    if (!_isDrawingGeofence) {
      return;
    }

    setState(() {
      if (_draftGeofenceStart == null) {
        _draftGeofenceStart = point;
        return;
      }

      if (_draftGeofenceEnd == null) {
        _draftGeofenceEnd = point;
        return;
      }

      final toStart = _geoDistance.as(
        LengthUnit.Meter,
        _draftGeofenceStart!,
        point,
      );
      final toEnd = _geoDistance.as(
        LengthUnit.Meter,
        _draftGeofenceEnd!,
        point,
      );
      if (toStart <= toEnd) {
        _draftGeofenceStart = point;
      } else {
        _draftGeofenceEnd = point;
      }
    });
  }

  String get _currentGpsText {
    final point = state.currentGpsPoint;
    if (point == null) {
      return '--';
    }
    final source = (state.currentGpsSource ?? state.gpsSourceText)
        .toUpperCase();
    return '${point.lat.toStringAsFixed(6)}, ${point.lon.toStringAsFixed(6)} [$source]';
  }

  void _snapDraftLineToCurrentGps(BuildContext context) {
    final point = state.currentGpsPoint;
    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No current GPS fix available yet.')),
      );
      return;
    }

    final center = LatLng(point.lat, point.lon);
    final headingDeg = state.currentGpsHeadingDeg ?? 0.0;
    const halfLineLengthMeters = 5.0;

    final start = _offsetByBearingMeters(
      origin: center,
      distanceMeters: halfLineLengthMeters,
      bearingDeg: headingDeg - 90.0,
    );
    final end = _offsetByBearingMeters(
      origin: center,
      distanceMeters: halfLineLengthMeters,
      bearingDeg: headingDeg + 90.0,
    );

    setState(() {
      _draftGeofenceStart = start;
      _draftGeofenceEnd = end;
      _geofenceDraftInitialized = true;
      _isDrawingGeofence = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _geofenceMapController.move(center, 18.0);
    });

    final source = (state.currentGpsSource ?? state.gpsSourceText)
        .toUpperCase();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Draft line snapped to current GPS ($source).')),
    );
  }

  LatLng _offsetByBearingMeters({
    required LatLng origin,
    required double distanceMeters,
    required double bearingDeg,
  }) {
    const earthRadiusMeters = 6378137.0;
    final angularDistance = distanceMeters / earthRadiusMeters;

    final lat1 = origin.latitude * pi / 180.0;
    final lon1 = origin.longitude * pi / 180.0;
    final bearingRad = bearingDeg * pi / 180.0;

    final sinLat2 =
        sin(lat1) * cos(angularDistance) +
        cos(lat1) * sin(angularDistance) * cos(bearingRad);
    final lat2 = asin(sinLat2.clamp(-1.0, 1.0));

    final lon2 =
        lon1 +
        atan2(
          sin(bearingRad) * sin(angularDistance) * cos(lat1),
          cos(angularDistance) - sin(lat1) * sin(lat2),
        );

    final normalizedLon = ((lon2 + pi) % (2 * pi)) - pi;
    return LatLng(lat2 * 180.0 / pi, normalizedLon * 180.0 / pi);
  }

  void _ensureGeofenceDraftInitialized() {
    if (_geofenceDraftInitialized) {
      return;
    }

    final start = _geoPointToLatLng(state.lapBoundaryStart);
    final end = _geoPointToLatLng(state.lapBoundaryEnd);

    _draftGeofenceStart = _isDefaultZeroPoint(start) ? null : start;
    _draftGeofenceEnd = _isDefaultZeroPoint(end) ? null : end;
    _geofenceDraftInitialized = true;
  }

  LatLng _geoPointToLatLng(GeoPoint point) {
    return LatLng(point.lat, point.lon);
  }

  bool _isDefaultZeroPoint(LatLng point) {
    return point.latitude.abs() < 0.001 && point.longitude.abs() < 0.001;
  }

  LatLng _resolveGeofenceMapCenter() {
    if (_draftGeofenceStart != null && _draftGeofenceEnd != null) {
      return LatLng(
        (_draftGeofenceStart!.latitude + _draftGeofenceEnd!.latitude) / 2,
        (_draftGeofenceStart!.longitude + _draftGeofenceEnd!.longitude) / 2,
      );
    }

    if (_draftGeofenceStart != null) {
      return _draftGeofenceStart!;
    }
    if (_draftGeofenceEnd != null) {
      return _draftGeofenceEnd!;
    }

    if (state.lastKnownLat != null && state.lastKnownLon != null) {
      return LatLng(state.lastKnownLat!, state.lastKnownLon!);
    }

    return const LatLng(14.5660, 120.9920);
  }

  void _animatedMapMove(LatLng destCenter, double destZoom) {
    if (!mounted) return;
    double startLat;
    double startLon;
    double startZoom;
    try {
      startLat = _geofenceMapController.camera.center.latitude;
      startLon = _geofenceMapController.camera.center.longitude;
      startZoom = _geofenceMapController.camera.zoom;
    } catch (_) {
      startLat = destCenter.latitude;
      startLon = destCenter.longitude;
      startZoom = destZoom;
    }

    final controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    final latTween = Tween<double>(begin: startLat, end: destCenter.latitude);
    final lonTween = Tween<double>(begin: startLon, end: destCenter.longitude);
    final zoomTween = Tween<double>(begin: startZoom, end: destZoom);

    controller.addListener(() {
      if (!mounted) return;
      _geofenceMapController.move(
        LatLng(latTween.evaluate(controller), lonTween.evaluate(controller)),
        zoomTween.evaluate(controller),
      );
    });

    controller.forward().then((_) => controller.dispose());
  }

  void _zoomIn() {
    if (!mounted) return;
    double currentZoom;
    LatLng center;
    try {
      currentZoom = _geofenceMapController.camera.zoom;
      center = _geofenceMapController.camera.center;
    } catch (_) {
      return;
    }
    final newZoom = (currentZoom + 1.0).clamp(1.0, 20.0);
    _animatedMapMove(center, newZoom);
  }

  void _zoomOut() {
    if (!mounted) return;
    double currentZoom;
    LatLng center;
    try {
      currentZoom = _geofenceMapController.camera.zoom;
      center = _geofenceMapController.camera.center;
    } catch (_) {
      return;
    }
    final newZoom = (currentZoom - 1.0).clamp(1.0, 20.0);
    _animatedMapMove(center, newZoom);
  }

  void _recenterOnGps() {
    if (state.hasCurrentGpsSample) {
      final target = LatLng(state.currentGpsLat!, state.currentGpsLon!);
      _animatedMapMove(target, 17.5);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No GPS location available to center.')),
      );
    }
  }

  Widget _buildScaleIndicator() {
    if (!mounted) {
      return const SizedBox.shrink();
    }
    MapCamera camera;
    try {
      camera = _geofenceMapController.camera;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final lat = camera.center.latitude;
    final zoom = camera.zoom;

    final metersPerPixel = (156543.03392 * cos(lat * pi / 180.0)) / pow(2.0, zoom);

    const distances = [
      1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000
    ];

    double bestDistance = 50.0;
    double bestWidth = 50.0;
    for (final d in distances) {
      final width = d / metersPerPixel;
      if (width >= 45.0) {
        bestDistance = d.toDouble();
        bestWidth = width;
        break;
      }
    }

    final label = bestDistance >= 1000.0
        ? '${(bestDistance / 1000.0).toStringAsFixed(0)} km'
        : '${bestDistance.toStringAsFixed(0)} m';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: p.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.cyan,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 3),
          Container(
            width: bestWidth,
            height: 3,
            decoration: BoxDecoration(
              color: p.cyan,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapFabStack() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border.withValues(alpha: 0.5), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildMapFabIcon(
            icon: Icons.add_rounded,
            tooltip: 'Zoom In',
            onTap: _zoomIn,
          ),
          Divider(color: p.border.withValues(alpha: 0.5), height: 1),
          _buildMapFabIcon(
            icon: Icons.remove_rounded,
            tooltip: 'Zoom Out',
            onTap: _zoomOut,
          ),
          Divider(color: p.border.withValues(alpha: 0.5), height: 1),
          _buildMapFabIcon(
            icon: Icons.my_location_rounded,
            tooltip: 'Recenter on Me',
            color: state.hasCurrentGpsSample ? p.cyan : p.dimText,
            onTap: state.hasCurrentGpsSample ? _recenterOnGps : null,
          ),
        ],
      ),
    );
  }

  Widget _buildMapFabIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 20,
            color: color ?? (onTap == null ? p.dimText : p.mainText),
          ),
        ),
      ),
    );
  }

  Widget _buildGpsWaitingOverlay() {
    final showOverlay = !state.gpsLocked &&
        _draftGeofenceStart == null &&
        _draftGeofenceEnd == null &&
        !_dismissGpsWaitingOverlay;

    if (!showOverlay) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.7),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: p.cyan,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Waiting for GPS fix...',
              style: TextStyle(
                color: p.mainText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () {
                setState(() {
                  _dismissGpsWaitingOverlay = true;
                });
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: p.border),
                  borderRadius: BorderRadius.circular(6),
                  color: const Color(0xFF181818),
                ),
                child: Text(
                  'Manual Pan & Draw',
                  style: TextStyle(
                    color: p.cyan,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatLatLng(LatLng? point) {
    if (point == null) {
      return '--';
    }
    return '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  }

  Widget _buildThrottleSection(BuildContext context) {
    final hasUnsavedProfile = state.selectedThrottleMapProfile.isEmpty;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Throttle Mapping',
            subtitle:
                'Edit curve safely in draft mode, then explicitly flash to controller.',
          ),
          _settingsCard(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final chartHeight = constraints.maxWidth < 520
                    ? 190.0
                    : constraints.maxWidth < 860
                    ? 220.0
                    : 250.0;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (state.throttleMapPresetNames.contains('Default'))
                          ChoiceChip(
                            label: const Text('Default'),
                            selected:
                                state.selectedThrottleMapProfile == 'Default',
                            selectedColor: p.orange.withValues(alpha: 0.16),
                            side: BorderSide(
                              color:
                                  state.selectedThrottleMapProfile == 'Default'
                                  ? p.orange
                                  : p.border,
                            ),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            labelPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            labelStyle: TextStyle(
                              color:
                                  state.selectedThrottleMapProfile == 'Default'
                                  ? p.orange
                                  : p.dimText,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            onSelected: (_) {
                              state.loadThrottleMapPreset('Default');
                            },
                          ),
                        ...state.customThrottleMapPresetNames
                            .where((name) => name != 'Default')
                            .map((profileName) {
                              final selected =
                                  state.selectedThrottleMapProfile ==
                                  profileName;
                              return ChoiceChip(
                                label: Text(profileName),
                                selected: selected,
                                selectedColor: p.orange.withValues(alpha: 0.16),
                                side: BorderSide(
                                  color: selected ? p.orange : p.border,
                                ),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                labelPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                labelStyle: TextStyle(
                                  color: selected ? p.orange : p.dimText,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                                onSelected: (_) {
                                  state.loadThrottleMapPreset(profileName);
                                },
                              );
                            }),
                        InkWell(
                          onTap: () => _showAddThrottleProfileDialog(context),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              border: Border.all(color: p.border),
                              color: p.light
                                  ? Colors.grey.shade100
                                  : const Color(0xFF111111),
                            ),
                            child: Icon(
                              Icons.add_rounded,
                              size: 15,
                              color: p.cyan,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: chartHeight,
                      child: LayoutBuilder(
                        builder: (context, chartConstraints) {
                          final chartSize = Size(
                            chartConstraints.maxWidth,
                            chartConstraints.maxHeight,
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanDown: (details) {
                              _updateThrottleMapFromGraph(
                                state,
                                details.localPosition,
                                chartSize,
                              );
                            },
                            onPanUpdate: (details) {
                              _updateThrottleMapFromGraph(
                                state,
                                details.localPosition,
                                chartSize,
                              );
                            },
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: p.border),
                                color: p.light
                                    ? Colors.grey.shade100
                                    : const Color(0xFF101010),
                              ),
                              child: CustomPaint(
                                painter: ThrottleMapPainter(
                                  p: p,
                                  values: state.throttleMapDraft,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: p.border),
                        color: p.light
                            ? Colors.grey.shade100
                            : const Color(0xFF101010),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: List.generate(5, (index) {
                          final inVal = index * 25;
                          final outVal = state.throttleMapDraft[index]
                              .toStringAsFixed(0);

                          return Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$inVal% IN',
                                  style: TextStyle(
                                    color: p.dimText,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$outVal%',
                                  style: TextStyle(
                                    color: p.mainText,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: state.throttleMapDirty ? p.amber : p.border,
                          width: 1,
                        ),
                        color: p.light
                            ? Colors.grey.shade100
                            : const Color(0xFF101010),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _buildThrottleStatusPill(
                            label: state.throttleMapDirty
                                ? 'UNFLASHED CHANGES'
                                : 'MAP FLASHED',
                            color: state.throttleMapDirty ? p.amber : p.green,
                          ),
                          if (hasUnsavedProfile)
                            _buildThrottleStatusPill(
                              label: 'UNSAVED PROFILE',
                              color: p.cyan,
                            ),
                          if (state.throttleMapDirty)
                            _buildThrottleStatusPill(
                              label: 'REVERT',
                              color: p.red,
                              onTap: state.resetThrottleMapDraftToApplied,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () {
                        state.applyThrottleMapDraft();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Throttle map flashed to controller.',
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: p.red.withValues(alpha: 0.16),
                          border: Border.all(color: p.red, width: 1.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.upload_rounded, color: p.red, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'FLASH TO CONTROLLER',
                              style: TextStyle(
                                color: p.red,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.8,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSection(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Session Rules',
            subtitle: 'Applies to the next Start Session flow.',
          ),
          _settingsCard(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'LAP DIVIDER',
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      state.lapDividerModeText,
                      style: TextStyle(
                        color: p.cyan,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('GEOFENCE'),
                      selected: state.lapDividerMode == LapDividerMode.geofence,
                      selectedColor: p.cyan.withValues(alpha: 0.18),
                      side: BorderSide(
                        color: state.lapDividerMode == LapDividerMode.geofence
                            ? p.cyan
                            : p.border,
                      ),
                      onSelected: (_) {
                        state.setLapDividerMode(LapDividerMode.geofence);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('DISTANCE'),
                      selected: state.lapDividerMode == LapDividerMode.distance,
                      selectedColor: p.orange.withValues(alpha: 0.16),
                      side: BorderSide(
                        color: state.lapDividerMode == LapDividerMode.distance
                            ? p.orange
                            : p.border,
                      ),
                      onSelected: (_) {
                        state.setLapDividerMode(LapDividerMode.distance);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('NONE'),
                      selected: state.lapDividerMode == LapDividerMode.none,
                      selectedColor: p.red.withValues(alpha: 0.16),
                      side: BorderSide(
                        color: state.lapDividerMode == LapDividerMode.none
                            ? p.red
                            : p.border,
                      ),
                      onSelected: (_) {
                        state.setLapDividerMode(LapDividerMode.none);
                      },
                    ),
                  ],
                ),
                if (state.lapDividerMode == LapDividerMode.distance) ...[
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'DISTANCE PER LAP',
                        style: TextStyle(
                          color: p.dimText,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        state.distanceLapDividerKmText,
                        style: TextStyle(
                          color: p.orange,
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: state.distanceLapDividerKm,
                    min: 0.05,
                    max: 5.0,
                    divisions: 99,
                    activeColor: p.orange,
                    onChanged: state.setDistanceLapDividerKm,
                  ),
                ],
                if (state.lapDividerMode == LapDividerMode.geofence) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'CROSSING DEADZONE',
                        style: TextStyle(
                          color: p.dimText,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        state.crossingDeadzoneConfigText,
                        style: TextStyle(
                          color: p.orange,
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: state.crossingDeadzoneMs.toDouble(),
                    min: 1000,
                    max: 10000,
                    divisions: 18,
                    activeColor: p.orange,
                    onChanged: (val) => state.setCrossingDeadzoneMs(
                      ((val / 500).round() * 500),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'GPS FALLBACK PERIOD',
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      state.gpsFallbackPeriodText,
                      style: TextStyle(
                        color: p.amber,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: state.gpsFallbackPeriodMs.toDouble(),
                  min: 1000,
                  max: 30000,
                  divisions: 58,
                  activeColor: p.amber,
                  onChanged: (val) =>
                      state.setGpsFallbackPeriodMs((val / 500).round() * 500),
                ),
              ],
            ),
          ),
          if (state.lapDividerMode == LapDividerMode.geofence) ...[
            const SizedBox(height: 12),
            _buildSectionHeader(
              title: 'Lap Crossing Geofence',
              subtitle:
                  'Draw the finish line directly on the map and apply it to lap detection.',
            ),
            _buildGeofenceEditorCard(context),
          ] else ...[
            const SizedBox(height: 12),
            _settingsCard(
              child: Text(
                state.lapDividerMode == LapDividerMode.distance
                    ? 'Geofence editor hidden because lap divider is DISTANCE mode.'
                    : 'Geofence editor hidden because lap divider is NONE mode.',
                style: TextStyle(color: p.dimText, fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAlertsSection() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Driver Alert Channels',
            subtitle: 'Tune non-visual alert behavior.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _configSwitch(
                    'ALERT AUDIO',
                    state.alertAudioEnabled,
                    (val) => state.setAlertAudioEnabled(val),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _configSwitch(
                    'ALERT HAPTICS',
                    state.alertHapticsEnabled,
                    (val) => state.setAlertHapticsEnabled(val),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _configSwitch(
                    'ADVISORY CUES',
                    state.alertAdvisoryEnabled,
                    (val) => state.setAlertAdvisoryEnabled(val),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'ALERT VOLUME',
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      state.alertVolumePercentText,
                      style: TextStyle(
                        color: p.cyan,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: state.alertVolume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  activeColor: p.orange,
                  onChanged: (val) => state.setAlertVolume(val),
                ),
                _buildCmdBtn('TEST ALERT TONE', () {
                  state.requestAlertTestTone();
                }, compact: true),
                const SizedBox(height: 8),
                Text(
                  'LAST ALERT: ${state.lastAlertSeverityText} ${state.lastAlertCode}',
                  style: TextStyle(
                    color: p.dimText,
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageSection() {
    final activeSessionId = state.sessionId.isEmpty
        ? 'pending-session'
        : state.sessionId;
    final normalizedSessionId = activeSessionId.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final csvDirectory = state.readableCopyDirectoryPath;
    final activeSessionCsvPath = csvDirectory == null
        ? '--'
        : '$csvDirectory/session_$normalizedSessionId.csv';
    final queueColor = state.spoolCapacityWarning
        ? p.red
        : (state.unsentBatchCount > 0 ? p.orange : p.lightGreen);
    final stateColor = state.sessionState == SessionState.logging
        ? p.lightGreen
        : state.sessionState == SessionState.armed
        ? p.orange
        : p.mainText;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Session CSV Storage',
            subtitle: 'Writes telemetry to one CSV per session/start.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildStorageBadge(
                      label: 'MODE',
                      value: 'CSV ONLY',
                      color: p.lightGreen,
                    ),
                    _buildStorageBadge(
                      label: 'STATE',
                      value: state.sessionStateWire,
                      color: stateColor,
                    ),
                    _buildStorageBadge(
                      label: 'QUEUE',
                      value: '${state.unsentBatchCount}',
                      color: queueColor,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildStorageField(
                  label: 'ACTIVE SESSION',
                  value: activeSessionId,
                  valueColor: p.cyan,
                ),
                const SizedBox(height: 8),
                _buildStorageField(
                  label: 'SESSION NAME',
                  value: state.sessionName.isEmpty ? '--' : state.sessionName,
                  monospace: false,
                ),
                const SizedBox(height: 8),
                _buildStorageField(
                  label: 'CSV DIRECTORY',
                  value: csvDirectory ?? '--',
                ),
                const SizedBox(height: 8),
                _buildStorageField(
                  label: 'ACTIVE CSV FILE',
                  value: activeSessionCsvPath,
                ),
                const SizedBox(height: 8),
                Text(
                  'Decoded telemetry appends to one CSV per session while LOGGING. Spool replay remains active for robust offline recovery.',
                  style: TextStyle(
                    color: p.dimText,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (state.readableCopyPreviewError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    state.readableCopyPreviewError!,
                    style: TextStyle(
                      color: p.red,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplaySection() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Display & Drive Settings',
            subtitle: 'Runtime UI and driver-assist configuration.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _configSwitch(
                  'LIGHT THEME (TRACK DAY)',
                  state.useLightTheme,
                  (val) => state.toggleTheme(val),
                ),
                const SizedBox(height: 8),
                _configSwitch(
                  'ENABLE MOCK SIMULATION',
                  state.enableSimulation,
                  (val) => state.toggleSimulation(val),
                ),
                const SizedBox(height: 8),
                _configSwitch(
                  'USE DICTIONARY TX FOR AUX COMMANDS',
                  state.useDictionaryAuxDispatch,
                  (val) => state.toggleDictionaryAuxDispatch(val),
                ),
                const SizedBox(height: 12),
                Text(
                  'GRAPH METRIC',
                  style: TextStyle(
                    color: p.dimText,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: state.graphMetric,
                  dropdownColor: p.light
                      ? Colors.white
                      : const Color(0xFF1E1E1E),
                  style: TextStyle(
                    color: p.cyan,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'speed', child: Text('SPEED')),
                    DropdownMenuItem(value: 'power', child: Text('POWER (W)')),
                    DropdownMenuItem(
                      value: 'efficiency',
                      child: Text('EFFICIENCY'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) state.updateGraphMetric(val);
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'GRAPH Y-AXIS RANGE',
                  style: TextStyle(
                    color: p.dimText,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: state.graphYMin.toStringAsFixed(0),
                        style: TextStyle(
                          color: p.cyan,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          labelText: 'MIN',
                          labelStyle: TextStyle(color: p.dimText, fontSize: 10),
                          filled: true,
                          fillColor: p.light
                              ? Colors.grey.shade200
                              : Colors.black,
                          contentPadding: const EdgeInsets.all(8),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          final v = double.tryParse(val);
                          if (v != null) {
                            state.updateGraphYRange(v, state.graphYMax);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        initialValue: state.graphYMax.toStringAsFixed(0),
                        style: TextStyle(
                          color: p.cyan,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          labelText: 'MAX',
                          labelStyle: TextStyle(color: p.dimText, fontSize: 10),
                          filled: true,
                          fillColor: p.light
                              ? Colors.grey.shade200
                              : Colors.black,
                          contentPadding: const EdgeInsets.all(8),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          final v = double.tryParse(val);
                          if (v != null) {
                            state.updateGraphYRange(state.graphYMin, v);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'SPEED BAR THRESHOLDS',
                  style: TextStyle(
                    color: p.dimText,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: state.speedLowerThreshold.toStringAsFixed(
                          0,
                        ),
                        style: TextStyle(
                          color: p.cyan,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          labelText: 'BURN ↓',
                          labelStyle: TextStyle(color: p.dimText, fontSize: 10),
                          filled: true,
                          fillColor: p.light
                              ? Colors.grey.shade200
                              : Colors.black,
                          contentPadding: const EdgeInsets.all(8),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          final v = double.tryParse(val);
                          if (v != null) {
                            state.updateSpeedThresholds(
                              v,
                              state.speedUpperThreshold,
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        initialValue: state.speedUpperThreshold.toStringAsFixed(
                          0,
                        ),
                        style: TextStyle(
                          color: p.orange,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          labelText: 'COAST ↑',
                          labelStyle: TextStyle(color: p.dimText, fontSize: 10),
                          filled: true,
                          fillColor: p.light
                              ? Colors.grey.shade200
                              : Colors.black,
                          contentPadding: const EdgeInsets.all(8),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          final v = double.tryParse(val);
                          if (v != null) {
                            state.updateSpeedThresholds(
                              state.speedLowerThreshold,
                              v,
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddThrottleProfileDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: p.light ? Colors.white : const Color(0xFF121212),
          title: Text(
            'Save Throttle Profile',
            style: TextStyle(color: p.mainText, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: p.cyan, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Profile Name',
              labelStyle: TextStyle(color: p.dimText),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CANCEL', style: TextStyle(color: p.dimText)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('SAVE'),
            ),
          ],
        );
      },
    );

    if (!context.mounted || name == null) {
      return;
    }

    final saved = state.addThrottleMapPreset(name);
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Unable to save profile. Use a unique non-default name.',
          ),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Profile "$name" saved.')));
  }

  void _updateThrottleMapFromGraph(
    DashboardState state,
    Offset localPosition,
    Size size,
  ) {
    const pad = 18.0;
    final chartWidth = max(1.0, size.width - (pad * 2));
    final chartHeight = max(1.0, size.height - (pad * 2));

    final normalizedX = ((localPosition.dx - pad) / chartWidth).clamp(0.0, 1.0);
    final index = (normalizedX * 4).round().clamp(0, 4);

    final normalizedY = ((chartHeight - (localPosition.dy - pad)) / chartHeight)
        .clamp(0.0, 1.0);
    final outputPercent = normalizedY * 100.0;

    state.updateThrottleMap(index, outputPercent);
  }

  Widget _buildSectionHeader({required String title, String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: p.mainText,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: p.dimText, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _settingsCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: p.border, width: 1),
        color: p.light ? Colors.white : const Color(0xFF101010),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  Widget _configSwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(
                color: p.dimText,
                fontWeight: FontWeight.bold,
                fontSize: 10,
              ),
            ),
          ),
        ),
        Switch(value: value, activeThumbColor: p.amber, onChanged: onChanged),
      ],
    );
  }

  Widget _infoRow(String label, String val, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.dimText,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: Text(
              val,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: valueColor ?? p.mainText,
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThrottleStatusPill({
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.75)),
        color: color.withValues(alpha: 0.14),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    if (onTap == null) {
      return chip;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: chip,
    );
  }

  Widget _buildStorageBadge({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.75)),
        color: color.withValues(alpha: 0.12),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _buildStorageField({
    required String label,
    required String value,
    Color? valueColor,
    bool monospace = true,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
        color: p.light ? Colors.grey.shade100 : const Color(0xFF111111),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.dimText,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? p.mainText,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              fontFamily: monospace ? 'monospace' : null,
              fontFeatures: monospace
                  ? const [FontFeature.tabularFigures()]
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCmdBtn(
    String label,
    VoidCallback onTap, {
    bool compact = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
        decoration: BoxDecoration(
          border: Border.all(color: p.dimText),
          color: p.light ? Colors.grey.shade200 : const Color(0xFF141414),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: p.mainText,
            fontWeight: FontWeight.bold,
            fontSize: compact ? 10 : 12,
          ),
        ),
      ),
    );
  }
}

class _PulsingUserLocationMarker extends StatefulWidget {
  const _PulsingUserLocationMarker();

  @override
  State<_PulsingUserLocationMarker> createState() => _PulsingUserLocationMarkerState();
}

class _PulsingUserLocationMarkerState extends State<_PulsingUserLocationMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
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
                color: Colors.blue.withValues(alpha: 0.6 * (1.0 - _pulseController.value)),
              ),
            ),
            Container(
              width: 12.0,
              height: 12.0,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue,
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



