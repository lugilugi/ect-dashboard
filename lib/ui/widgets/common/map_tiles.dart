import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Road-first base layer for all maps in the app.
///
/// Light theme uses CARTO Voyager (roads have dark casings + bright fills, so
/// they read clearly on the beige land). Dark theme keeps CARTO Dark Matter
/// for the ambient look but lifts it with a brightness/contrast matrix so the
/// grey road fills stop melting into the near-black background.
class RoadMapTileLayer extends StatelessWidget {
  final bool useLightTheme;

  const RoadMapTileLayer({super.key, required this.useLightTheme});

  static const List<double> _darkRoadBoost = [
    1.35, 0, 0, 0, 30, //
    0, 1.35, 0, 0, 30, //
    0, 0, 1.35, 0, 30, //
    0, 0, 0, 1, 0, //
  ];

  @override
  Widget build(BuildContext context) {
    final tiles = TileLayer(
      urlTemplate: useLightTheme
          ? 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png'
          : 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.example.telemetry_dashboard',
      maxNativeZoom: 19,
      maxZoom: 20,
    );
    if (useLightTheme) {
      return tiles;
    }
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_darkRoadBoost),
      child: tiles,
    );
  }
}
