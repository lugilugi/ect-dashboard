import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/orchestration/lap_boundary_service.dart';

void main() {
  group('DashboardState lap crossing records', () {
    test('records completed geofence crossings with GPS position', () {
      final state = DashboardState();
      addTearDown(state.dispose);

      // Restore a logging session deterministically (bypasses the standstill
      // start gate).
      state.restoreFromCheckpoint(
        SessionCheckpointSnapshot(
          sessionId: 'test-session',
          sessionName: 'Crossing Test',
          sessionState: SessionState.logging,
          uiMode: UiMode.driver,
          lapsCompleted: 0,
          lapPhase: LapPhase.running,
          crossingDeadzoneMs: 3000,
          crossingDeadzoneRemainingMs: 0,
          crossingValid: false,
          lapNumber: 1,
          sessionTimeSeconds: 10,
          lastSeqInSession: 0,
          gpsLocked: true,
          usingPhoneGpsFallback: false,
          updatedAtUtc: DateTime.utc(2026, 1, 1),
        ),
      );

      // Finish line along the equator from (0,0) to (0,0.0001) — crossing it
      // means travelling north (heading 0).
      state.configureLapBoundary(
        start: const GeoPoint(lat: 0, lon: 0),
        end: const GeoPoint(lat: 0, lon: 0.0001),
      );
      expect(state.lapBoundaryConfigured, isTrue);

      final t0 = DateTime.utc(2026, 1, 1, 0, 0, 0);

      // Approach from the south.
      state.processGpsSample(
        lat: -0.0001,
        lon: 0,
        headingDeg: 0,
        speedKmh: 5.0,
        timestampUtc: t0,
        source: 'external_gps',
      );
      expect(state.lapsCompleted, 0);

      // Cross the line heading north -> lap accepted.
      state.processGpsSample(
        lat: 0.0001,
        lon: 0,
        headingDeg: 0,
        speedKmh: 5.0,
        timestampUtc: t0.add(const Duration(seconds: 2)),
        source: 'external_gps',
      );
      expect(state.lapsCompleted, 1);
      expect(state.lapCrossings, hasLength(1));
      expect(state.lapCrossings.first.lapNumber, 1);
      expect(state.lapCrossings.first.lat, 0.0001);
      expect(state.lapCrossings.first.lon, 0);

      // Crossing again inside the deadzone does not record a second lap.
      state.processGpsSample(
        lat: -0.0001,
        lon: 0,
        headingDeg: 180,
        speedKmh: 5.0,
        timestampUtc: t0.add(const Duration(seconds: 4)),
        source: 'external_gps',
      );
      state.processGpsSample(
        lat: 0.0001,
        lon: 0,
        headingDeg: 0,
        speedKmh: 5.0,
        timestampUtc: t0.add(const Duration(seconds: 6)),
        source: 'external_gps',
      );
      expect(state.lapsCompleted, 1);
      expect(state.lapCrossings, hasLength(1));

      // After the deadzone and min lap time, a second lap is recorded.
      state.processGpsSample(
        lat: -0.0001,
        lon: 0,
        headingDeg: 180,
        speedKmh: 5.0,
        timestampUtc: t0.add(const Duration(seconds: 70)),
        source: 'external_gps',
      );
      state.processGpsSample(
        lat: 0.0001,
        lon: 0,
        headingDeg: 0,
        speedKmh: 5.0,
        timestampUtc: t0.add(const Duration(seconds: 72)),
        source: 'external_gps',
      );
      expect(state.lapsCompleted, 2);
      expect(state.lapCrossings, hasLength(2));
      expect(state.lapCrossings.last.lapNumber, 2);
    });

    test('crossing history clears with the session state', () {
      final state = DashboardState();
      addTearDown(state.dispose);

      state.restoreFromCheckpoint(
        SessionCheckpointSnapshot(
          sessionId: 'test-session',
          sessionName: 'Clear Test',
          sessionState: SessionState.logging,
          uiMode: UiMode.driver,
          lapsCompleted: 0,
          lapPhase: LapPhase.running,
          crossingDeadzoneMs: 3000,
          crossingDeadzoneRemainingMs: 0,
          crossingValid: false,
          lapNumber: 1,
          sessionTimeSeconds: 5,
          lastSeqInSession: 0,
          gpsLocked: true,
          usingPhoneGpsFallback: false,
          updatedAtUtc: DateTime.utc(2026, 1, 1),
        ),
      );
      state.configureLapBoundary(
        start: const GeoPoint(lat: 0, lon: 0),
        end: const GeoPoint(lat: 0, lon: 0.0001),
      );

      final t0 = DateTime.utc(2026, 1, 1, 0, 1, 0);
      state.processGpsSample(
        lat: -0.0001,
        lon: 0,
        headingDeg: 0,
        speedKmh: 5.0,
        timestampUtc: t0,
        source: 'external_gps',
      );
      state.processGpsSample(
        lat: 0.0001,
        lon: 0,
        headingDeg: 0,
        speedKmh: 5.0,
        timestampUtc: t0.add(const Duration(seconds: 2)),
        source: 'external_gps',
      );
      expect(state.lapCrossings, hasLength(1));

      state.resetSessionState();
      expect(state.lapCrossings, isEmpty);
    });
  });
}
