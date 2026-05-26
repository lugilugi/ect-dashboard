import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/alerts/driver_alert_models.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/orchestration/driver_alert_service.dart';
import 'package:telemetry_dashboard/services/orchestration/lap_boundary_service.dart';

class _FakeAlertOutput implements DriverAlertOutput {
  final List<DriverAlertSeverity> audioEvents = <DriverAlertSeverity>[];

  @override
  Future<void> playAudio({
    required DriverAlertSeverity severity,
    required double volume,
  }) async {
    audioEvents.add(severity);
  }

  @override
  Future<void> playHaptic({required DriverAlertSeverity severity}) async {}

  int audioCount(DriverAlertSeverity severity) {
    return audioEvents.where((event) => event == severity).length;
  }
}

SessionCheckpointSnapshot _loggingSnapshot(String sessionId) {
  return SessionCheckpointSnapshot(
    sessionId: sessionId,
    sessionName: 'Hardening Session',
    sessionState: SessionState.logging,
    uiMode: UiMode.driver,
    lapsCompleted: 0,
    lapPhase: LapPhase.running,
    crossingDeadzoneMs: 3000,
    crossingDeadzoneRemainingMs: 0,
    crossingValid: false,
    lapNumber: 1,
    sessionTimeSeconds: 0,
    lastSeqInSession: 0,
    gpsLocked: true,
    usingPhoneGpsFallback: false,
    updatedAtUtc: DateTime.now().toUtc(),
  );
}

Future<void> _drainQueue([int ticks = 8]) async {
  for (int i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('Phase 7 alert hardening', () {
    test('jittered crossing bursts do not overcount laps during deadzone', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      final service = DriverAlertService(state: state, output: output);
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot('phase7-deadzone-1'));
      state.setAlertHapticsEnabled(false);
      state.configureLapBoundary(
        start: const GeoPoint(lat: 0, lon: -1),
        end: const GeoPoint(lat: 0, lon: 1),
      );

      final t0 = DateTime.now().toUtc();
      state.processGpsSample(
        lat: -1,
        lon: 0,
        headingDeg: 0,
        speedKmh: 12,
        timestampUtc: t0,
        source: 'test',
      );
      state.processGpsSample(
        lat: 1,
        lon: 0,
        headingDeg: 0,
        speedKmh: 12,
        timestampUtc: t0.add(const Duration(seconds: 2)),
        source: 'test',
      );

      for (int i = 0; i < 4; i++) {
        final burstStart = t0.add(Duration(milliseconds: 2200 + (i * 150)));
        state.processGpsSample(
          lat: -1,
          lon: 0,
          headingDeg: 0,
          speedKmh: 14,
          timestampUtc: burstStart,
          source: 'test',
        );
        state.processGpsSample(
          lat: 1,
          lon: 0,
          headingDeg: 0,
          speedKmh: 14,
          timestampUtc: burstStart.add(const Duration(milliseconds: 60)),
          source: 'test',
        );
      }
      await _drainQueue();

      expect(state.lapsCompleted, 1);
      expect(output.audioCount(DriverAlertSeverity.advisory), 1);

      service.stop();
      state.dispose();
    });

    test('disconnect fault injection loop remains bounded by cooldown', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      DateTime now = DateTime.utc(2026, 4, 17, 14, 0, 0);

      final service = DriverAlertService(
        state: state,
        output: output,
        nowProvider: () => now,
      );
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot('phase7-cooldown-1'));
      state.setAlertHapticsEnabled(false);
      state.setAlertCooldownMs(3000);
      state.setConnectionState(true);
      state.setServerConnectionState(true);
      await _drainQueue();

      for (int i = 0; i < 50; i++) {
        state.setConnectionState(true);
        await _drainQueue(2);
        state.setConnectionState(false);
        await _drainQueue(2);
      }

      expect(output.audioCount(DriverAlertSeverity.warning), 1);

      now = now.add(const Duration(seconds: 4));
      state.setConnectionState(true);
      await _drainQueue();
      state.setConnectionState(false);
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.warning), 2);

      service.stop();
      state.dispose();
    });

    test('fault class transitions are auditable without duplicate storms', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      DateTime now = DateTime.utc(2026, 4, 17, 15, 0, 0);

      final service = DriverAlertService(
        state: state,
        output: output,
        nowProvider: () => now,
      );
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot('phase7-faultclass-1'));
      state.setAlertHapticsEnabled(false);
      state.setAlertCooldownMs(5000);

      state.updateErrorCode('OVER_TEMP');
      await _drainQueue();
      for (int i = 0; i < 5; i++) {
        state.updateErrorCode('OVER_TEMP');
        await _drainQueue(2);
      }

      expect(output.audioCount(DriverAlertSeverity.critical), 1);
      expect(state.lastAlertCode, 'critical_fault_THERMAL');

      now = now.add(const Duration(milliseconds: 200));
      state.updateErrorCode('CAN_BUS_FAIL');
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.critical), 2);
      expect(state.lastAlertCode, 'critical_fault_LINK');

      service.stop();
      state.dispose();
    });
  });
}
