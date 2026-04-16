import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/driver_alert_models.dart';
import 'package:telemetry_dashboard/models/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/driver_alert_service.dart';
import 'package:telemetry_dashboard/services/lap_boundary_service.dart';

class _FakeAlertOutput implements DriverAlertOutput {
  final List<DriverAlertSeverity> audioEvents = <DriverAlertSeverity>[];
  final List<DriverAlertSeverity> hapticEvents = <DriverAlertSeverity>[];

  @override
  Future<void> playAudio({
    required DriverAlertSeverity severity,
    required double volume,
  }) async {
    audioEvents.add(severity);
  }

  @override
  Future<void> playHaptic({required DriverAlertSeverity severity}) async {
    hapticEvents.add(severity);
  }

  int audioCount(DriverAlertSeverity severity) {
    return audioEvents.where((event) => event == severity).length;
  }
}

SessionCheckpointSnapshot _loggingSnapshot({
  String sessionId = 'session-alert-1',
  int lapsCompleted = 0,
}) {
  return SessionCheckpointSnapshot(
    sessionId: sessionId,
    sessionName: 'Alert Test Session',
    sessionState: SessionState.logging,
    uiMode: UiMode.driver,
    lapsPlanned: 5,
    lapsCompleted: lapsCompleted,
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
  group('DriverAlertService', () {
    test('emits lap accepted advisory and lap rejected warning cues', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();

      final service = DriverAlertService(state: state, output: output);
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot());
      state.setAlertHapticsEnabled(false);
      state.setAlertAdvisoryEnabled(true);

      state.setLapsCompleted(1);
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.advisory), 1);
      expect(state.lastAlertCode, 'lap_accepted');
      expect(state.lastAlertSeverity, DriverAlertSeverity.advisory);

      state.configureLapBoundary(
        start: const GeoPoint(lat: 0, lon: -1),
        end: const GeoPoint(lat: 0, lon: 1),
      );
      final t0 = DateTime.now().toUtc();
      state.processGpsSample(
        lat: -1,
        lon: 0,
        headingDeg: 0,
        speedKmh: 10,
        timestampUtc: t0,
        source: 'test',
      );
      state.processGpsSample(
        lat: 1,
        lon: 0,
        headingDeg: 0,
        speedKmh: 0.1,
        timestampUtc: t0.add(const Duration(seconds: 1)),
        source: 'test',
      );
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.warning), 1);
      expect(state.lastAlertCode, startsWith('lap_rejected_'));
      expect(state.lastAlertSeverity, DriverAlertSeverity.warning);

      service.stop();
      state.dispose();
    });

    test('emits telemetry disconnect warning and blackout critical', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      final service = DriverAlertService(state: state, output: output);
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot(sessionId: 'session-alert-2'));
      state.setAlertHapticsEnabled(false);

      state.setConnectionState(true);
      state.setServerConnectionState(true);
      await _drainQueue();

      state.setConnectionState(false);
      await _drainQueue();
      expect(output.audioCount(DriverAlertSeverity.warning), 1);

      state.setServerConnectionState(false);
      await _drainQueue();
      expect(output.audioCount(DriverAlertSeverity.critical), 1);
      expect(state.lastAlertCode, 'telemetry_disconnect_blackout');

      service.stop();
      state.dispose();
    });

    test('deduplicates repeated alerts inside cooldown window', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      DateTime now = DateTime.utc(2026, 4, 17, 12, 0, 0);

      final service = DriverAlertService(
        state: state,
        output: output,
        nowProvider: () => now,
      );
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot(sessionId: 'session-alert-3'));
      state.setAlertHapticsEnabled(false);
      state.setAlertCooldownMs(2000);

      state.setConnectionState(true);
      state.setServerConnectionState(true);
      await _drainQueue();

      state.setConnectionState(false);
      await _drainQueue();

      state.setConnectionState(true);
      await _drainQueue();
      state.setConnectionState(false);
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.warning), 1);

      now = now.add(const Duration(seconds: 3));
      state.setConnectionState(true);
      await _drainQueue();
      state.setConnectionState(false);
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.warning), 2);

      service.stop();
      state.dispose();
    });

    test('plays repeated cadence for critical alerts', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      final service = DriverAlertService(state: state, output: output);
      service.start();

      state.restoreFromCheckpoint(_loggingSnapshot(sessionId: 'session-alert-4'));
      state.setAlertCriticalRepeatCount(2);
      state.setAlertCriticalRepeatIntervalMs(150);

      state.updateErrorCode('OVER_TEMP');
      await Future<void>.delayed(const Duration(milliseconds: 520));

      expect(output.audioCount(DriverAlertSeverity.critical), greaterThanOrEqualTo(3));
      expect(state.lastAlertSeverity, DriverAlertSeverity.critical);

      service.stop();
      state.dispose();
    });

    test('routes service-mode test tone request into warning cue', () async {
      final state = DashboardState();
      final output = _FakeAlertOutput();
      final service = DriverAlertService(state: state, output: output);
      service.start();

      state.requestAlertTestTone();
      await _drainQueue();

      expect(output.audioCount(DriverAlertSeverity.warning), 1);
      expect(state.lastAlertCode, 'manual_test_tone');

      service.stop();
      state.dispose();
    });
  });
}
