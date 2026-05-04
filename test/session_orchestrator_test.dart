import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/services/orchestration/session_orchestrator.dart';

SessionControlState _baseControl({
  SessionState sessionState = SessionState.idle,
  int lapsPlanned = 3,
  int lapsCompleted = 0,
}) {
  return SessionControlState(
    sessionState: sessionState,
    uiMode: UiMode.driver,
    lapsPlanned: lapsPlanned,
    lapsCompleted: lapsCompleted,
    lapPhase: LapPhase.prestartCheck,
    crossingDeadzoneMs: 3000,
    crossingDeadzoneRemainingMs: 0,
    crossingValid: false,
  );
}

void main() {
  group('SessionOrchestrator', () {
    test('blocks start when vehicle is not at standstill threshold', () {
      final orchestrator = SessionOrchestrator(
        standstillThresholdKmh: 0.5,
        standstillHold: const Duration(milliseconds: 800),
      );

      final now = DateTime.now().toUtc();
      final armed = orchestrator.arm(control: _baseControl());
      final decision = orchestrator.requestStart(
        control: armed,
        speedKmh: 2.0,
        nowUtc: now,
      );

      expect(decision.accepted, isFalse);
      expect(decision.reason, isNotNull);
      expect(decision.nextControl.sessionState, SessionState.armed);
    });

    test('allows start after standstill hold is satisfied', () {
      final orchestrator = SessionOrchestrator(
        standstillThresholdKmh: 0.5,
        standstillHold: const Duration(milliseconds: 800),
      );

      final base = DateTime.now().toUtc();
      final armed = orchestrator.arm(control: _baseControl());

      orchestrator.evaluateStartGate(speedKmh: 0.0, nowUtc: base);
      final decision = orchestrator.requestStart(
        control: armed,
        speedKmh: 0.0,
        nowUtc: base.add(const Duration(milliseconds: 900)),
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.logging);
      expect(decision.nextControl.lapPhase, LapPhase.running);
    });

    test('blocks normal stop when lap target is incomplete', () {
      final orchestrator = SessionOrchestrator();
      final control = _baseControl(
        sessionState: SessionState.logging,
        lapsPlanned: 4,
        lapsCompleted: 2,
      );

      final decision = orchestrator.requestStop(
        control: control,
        nowUtc: DateTime.now().toUtc(),
        abort: false,
        enforceLapTarget: true,
      );

      expect(decision.accepted, isFalse);
      expect(decision.reason, isNotNull);
      expect(decision.nextControl.sessionState, SessionState.logging);
    });

    test('allows stop on abort regardless of lap target', () {
      final orchestrator = SessionOrchestrator();
      final control = _baseControl(
        sessionState: SessionState.logging,
        lapsPlanned: 4,
        lapsCompleted: 1,
      );

      final decision = orchestrator.requestStop(
        control: control,
        nowUtc: DateTime.now().toUtc(),
        abort: true,
        enforceLapTarget: true,
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.ended);
      expect(decision.nextControl.lapPhase, LapPhase.sessionComplete);
    });
  });
}