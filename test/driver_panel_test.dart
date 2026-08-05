import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/ui/widgets/driver/efficiency_grid.dart';

void main() {
  group('Driver right panel', () {
    Future<void> pumpGrid(WidgetTester tester, DashboardState state) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1280,
              height: 800,
              child: EfficiencyGrid(state: state, p: Palette(false)),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows track map, session time, lap/distance/avg eff',
        (tester) async {
      final state = DashboardState();

      await pumpGrid(tester, state);

      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('SESSION TIME'), findsOneWidget);
      expect(find.text('LAP'), findsOneWidget);
      expect(find.text('DISTANCE'), findsOneWidget);
      expect(find.text('AVG EFF'), findsOneWidget);

      state.dispose();
    });

    testWidgets('energy and avg speed cells are gone', (tester) async {
      final state = DashboardState();

      await pumpGrid(tester, state);

      expect(find.text('ENERGY'), findsNothing);
      expect(find.textContaining(' Wh'), findsNothing);
      expect(find.text('AVG SPEED'), findsNothing);

      state.dispose();
    });

    testWidgets('GPS fix renders the car marker without the waiting overlay',
        (tester) async {
      final state = DashboardState();
      state.processGpsSample(
        lat: 14.5660,
        lon: 120.9920,
        headingDeg: 90,
        speedKmh: 30,
        timestampUtc: DateTime.now().toUtc(),
        source: 'test',
      );

      await pumpGrid(tester, state);

      expect(find.text('WAITING FOR GPS FIX...'), findsNothing);

      state.dispose();
    });
  });

  group('GPS track ring buffer', () {
    test('appends fixes, skips sub-step duplicates, caps at max', () {
      final state = DashboardState();
      final now = DateTime.now().toUtc();

      // ~111 m apart per 0.001 deg lat -> each step exceeds the 2 m dedupe.
      for (int i = 0; i < 405; i++) {
        state.processGpsSample(
          lat: 14.5 + i * 0.001,
          lon: 120.99,
          headingDeg: 0,
          speedKmh: 30,
          timestampUtc: now,
          source: 'test',
        );
      }

      expect(state.gpsTrackPoints.length, DashboardState.maxGpsTrackPoints);
      expect(state.gpsTrackPoints.first.lat, closeTo(14.505, 1e-9));
      expect(state.gpsTrackPoints.last.lat, closeTo(14.904, 1e-9));

      // Repeating the last fix (0 m step) does not append.
      final before = state.gpsTrackPoints.length;
      state.processGpsSample(
        lat: 14.904,
        lon: 120.99,
        headingDeg: 0,
        speedKmh: 30,
        timestampUtc: now,
        source: 'test',
      );
      expect(state.gpsTrackPoints.length, before);

      state.dispose();
    });
  });
}
