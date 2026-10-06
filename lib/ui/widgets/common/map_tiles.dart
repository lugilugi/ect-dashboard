import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shared key-free road tiles. Only viewed tiles are requested and cached;
/// dark styling happens locally so both themes reuse the same downloads.
class RoadMapTileLayer extends StatefulWidget {
  final bool useLightTheme;

  const RoadMapTileLayer({super.key, required this.useLightTheme});

  @override
  State<RoadMapTileLayer> createState() => _RoadMapTileLayerState();
}

class _RoadMapTileLayerState extends State<RoadMapTileLayer> {
  static final _store = _createStore();

  static Future<FileCacheStore> _createStore() async {
    final directory = await getApplicationCacheDirectory();
    return FileCacheStore(path.join(directory.path, 'map_tiles'));
  }

  late final Future<CachedTileProvider> _provider = _createProvider();

  Future<CachedTileProvider> _createProvider() async => CachedTileProvider(
    store: await _store,
    cachePolicy: CachePolicy.request,
    maxStale: const Duration(days: 7),
    headers: {
      'User-Agent':
          'ECT-Dashboard/3.0 (https://github.com/lugilugi/ect-dashboard)',
    },
  );

  // Inverted luminance leaves a dark background with readable road outlines.
  static const List<double> _darkRoadFilter = [
    -0.15945, -0.5364, -0.05415, 0, 210, //
    -0.15945, -0.5364, -0.05415, 0, 210, //
    -0.15945, -0.5364, -0.05415, 0, 210, //
    0, 0, 0, 1, 0, //
  ];
  static const List<double> _identityFilter = [
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  @override
  void dispose() {
    // The caching provider does not close its Dio client on TileLayer.dispose.
    _provider.then((provider) => provider.dio.close(), onError: (Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CachedTileProvider>(
    future: _provider,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(child: Text('Map tiles unavailable'));
      }
      final provider = snapshot.data;
      if (provider == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return ColorFiltered(
        colorFilter: ColorFilter.matrix(
          widget.useLightTheme ? _identityFilter : _darkRoadFilter,
        ),
        child: TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          tileProvider: provider,
          userAgentPackageName: 'com.example.telemetry_dashboard',
          maxNativeZoom: 19,
          maxZoom: 20,
          // OSM permits visible tiles, not speculative downloads around the view.
          panBuffer: 0,
        ),
      );
    },
  );
}

/// Place last in each map so attribution stays above tiles and GPS overlays.
class RoadMapAttribution extends StatelessWidget {
  const RoadMapAttribution({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomRight,
    child: Material(
      color: Colors.white.withValues(alpha: 0.9),
      child: InkWell(
        onTap: () async {
          await launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'));
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Text(
            '© OpenStreetMap contributors',
            style: TextStyle(
              color: Colors.black,
              fontSize: 10,
              fontWeight: FontWeight.normal,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    ),
  );
}
