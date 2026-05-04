import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/services/orchestration/lap_boundary_service.dart';

SessionControlState _loggingControl() {
  return const SessionControlState(
    sessionState: SessionState.logging,
    uiMode: UiMode.driver,
    lapsPlanned: 10,
    lapsCompleted: 0,
    lapPhase: LapPhase.running,
    crossingDeadzoneMs: 3000,
    crossingDeadzoneRemainingMs: 0,
    crossingValid: false,
  );
}

void main() {
  group('LapBoundaryService', () {
    test('accepts valid crossing and activates deadzone', () {
      final service = LapBoundaryService(
        config: const LapBoundaryConfig(
          finishLineStart: GeoPoint(lat: 0, lon: -1),
          finishLineEnd: GeoPoint(lat: 0, lon: 1),
          expectedHeadingDeg: 0,
          headingToleranceDeg: 45,
          minCrossingSpeedKmh: 1.0,
          minLapTime: Duration(seconds: 1),
          deadzone: Duration(seconds: 3),
        ),
      );

      final t0 = DateTime.now().toUtc();
      service.processSample(
        sample: GpsSample(
          point: const GeoPoint(lat: -1, lon: 0),
          headingDeg: 0,
          speedKmh: 10,
          tsUtc: t0,
          source: 'phone_gps',
        ),
        control: _loggingControl(),
        sessionId: 'session-a',
        lapNumber: 1,
      );

      final accepted = service.processSample(
        sample: GpsSample(
          point: const GeoPoint(lat: 1, lon: 0),
          headingDeg: 2,
          speedKmh: 12,
          tsUtc: t0.add(const Duration(seconds: 2)),
          source: 'phone_gps',
        ),
        control: _loggingControl(),
        sessionId: 'session-a',
        lapNumber: 1,
      );

      expect(accepted.decision, LapCrossingDecision.accepted);
      expect(accepted.crossingEvent?.crossingValid, isTrue);
      expect(accepted.deadzoneRemainingMs, 3000);

      final deadzone = service.processSample(
        sample: GpsSample(
          point: const GeoPoint(lat: -1, lon: 0),
          headingDeg: 0,
          speedKmh: 10,
          tsUtc: t0.add(const Duration(seconds: 3)),
          source: 'phone_gps',
        ),
        control: _loggingControl(),
        sessionId: 'session-a',
        lapNumber: 2,
      );

      expect(deadzone.decision, LapCrossingDecision.deadzone);
      expect(deadzone.crossingEvent, isNull);
      expect(deadzone.deadzoneRemainingMs, greaterThan(0));
    });

    test('rejects crossing below speed threshold', () {
      final service = LapBoundaryService(
        config: const LapBoundaryConfig(
          finishLineStart: GeoPoint(lat: 0, lon: -1),
          finishLineEnd: GeoPoint(lat: 0, lon: 1),
          expectedHeadingDeg: 0,
          headingToleranceDeg: 45,
          minCrossingSpeedKmh: 8.0,
          minLapTime: Duration(seconds: 1),
          deadzone: Duration(seconds: 3),
        ),
      );

      final t0 = DateTime.now().toUtc();
      service.processSample(
        sample: GpsSample(
          point: const GeoPoint(lat: -1, lon: 0),
          headingDeg: 0,
          speedKmh: 10,
          tsUtc: t0,
          source: 'phone_gps',
        ),
        control: _loggingControl(),
        sessionId: 'session-b',
        lapNumber: 1,
      );

      final rejected = service.processSample(
        sample: GpsSample(
          point: const GeoPoint(lat: 1, lon: 0),
          headingDeg: 0,
          speedKmh: 3,
          tsUtc: t0.add(const Duration(seconds: 2)),
          source: 'phone_gps',
        ),
        control: _loggingControl(),
        sessionId: 'session-b',
        lapNumber: 1,
      );

      expect(rejected.decision, LapCrossingDecision.rejected);
      expect(rejected.crossingEvent?.crossingValid, isFalse);
      expect(rejected.crossingEvent?.reason, 'speed_below_threshold');
    });
  });
}