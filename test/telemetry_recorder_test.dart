import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';

void main() {
  test('recorder preserves observation time and expires cached snapshots', () {
    final state = DashboardState();
    addTearDown(state.dispose);
    state.startSession('recorder');
    var now = DateTime.utc(2026, 10, 6);
    final recorder = TelemetryRecorder(state, nowUtc: () => now);
    final first = recorder.record(
      'Voltage_780',
      72.4,
      observedAtUtc: now,
      freshnessMs: 1000,
    );
    expect(first!.tsWallUtc, DateTime.utc(2026, 10, 6));
    now = now.add(const Duration(milliseconds: 500));
    expect(
      recorder.record(
        'Voltage_780',
        72.4,
        observedAtUtc: now,
        freshnessMs: 1000,
      ),
      isNull,
    );
    now = now.add(const Duration(milliseconds: 500));
    final snapshot = recorder.sampleFreshValues().single;
    expect(snapshot.observedAtUtc, DateTime.utc(2026, 10, 6, 0, 0, 0, 500));
    expect(snapshot.tsWallUtc, now);
    expect(snapshot.sampleKind, 'snapshot');
    now = now.add(const Duration(seconds: 2));
    expect(recorder.sampleFreshValues(), isEmpty);
  });

  test('session changes clear cached signals and restart sequence', () {
    final state = DashboardState();
    addTearDown(state.dispose);
    final recorder = TelemetryRecorder(state);
    state.startSession('one');
    final first = recorder.record('Speed_Kmh', 10)!;
    state.stopSession(abort: true);
    state.startSession('two');
    expect(recorder.sampleFreshValues(), isEmpty);
    final second = recorder.record('Speed_Kmh', 10)!;
    expect(second.sessionId, isNot(first.sessionId));
    expect(second.seqInSession, 1);
  });

  test('GPS siblings retain their common sample identity', () {
    final state = DashboardState();
    addTearDown(state.dispose);
    state.startSession('GPS');
    final recorder = TelemetryRecorder(state);
    final lat = recorder.record(
      'GPS_Latitude_Deg',
      14.5,
      source: 'phone_gps',
      sourceSampleId: 'fix-one',
    )!;
    final lon = recorder.record(
      'GPS_Longitude_Deg',
      121.0,
      source: 'phone_gps',
      sourceSampleId: 'fix-one',
    )!;
    expect(lat.sourceSampleId, lon.sourceSampleId);
    expect(lon.seqInSession, lat.seqInSession + 1);
    expect(lon.toJson()['schema_version'], 2);
    expect(lon.toJson()['signal_name'], 'GPS_Longitude_Deg');
  });
}
