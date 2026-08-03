import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/services/orchestration/session_orchestrator.dart';

SessionControlState _baseControl({
  SessionState sessionState = SessionState.idle,
  int lapsCompleted = 0,
}) {
  return SessionControlState(
    sessionState: sessionState,
    uiMode: UiMode.driver,
    lapsCompleted: lapsCompleted,
    lapPhase: LapPhase.prestartCheck,
    crossingDeadzoneMs: 3000,
    crossingDeadzoneRemainingMs: 0,
    crossingValid: false,
  );
}

void main() {
  group('SessionOrchestrator', () {
    test('allows start while the vehicle is moving', () {
      final orchestrator = SessionOrchestrator();
      final armed = orchestrator.arm(control: _baseControl());
      final decision = orchestrator.requestStart(
        control: armed,
        speedKmh: 2.0,
        nowUtc: DateTime.now().toUtc(),
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.logging);
      expect(decision.nextControl.lapPhase, LapPhase.running);
    });

    test('allows start immediately without a standstill hold', () {
      final orchestrator = SessionOrchestrator();
      final armed = orchestrator.arm(control: _baseControl());
      final decision = orchestrator.requestStart(
        control: armed,
        speedKmh: 0.0,
        nowUtc: DateTime.now().toUtc(),
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.logging);
    });

    test('allows normal stop from logging state', () {
      final orchestrator = SessionOrchestrator();
      final control = _baseControl(
        sessionState: SessionState.logging,
        lapsCompleted: 2,
      );

      final decision = orchestrator.requestStop(
        control: control,
        nowUtc: DateTime.now().toUtc(),
        abort: false,
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.ended);
    });

    test('allows stop on abort from any logging state', () {
      final orchestrator = SessionOrchestrator();
      final control = _baseControl(
        sessionState: SessionState.logging,
        lapsCompleted: 1,
      );

      final decision = orchestrator.requestStop(
        control: control,
        nowUtc: DateTime.now().toUtc(),
        abort: true,
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.ended);
      expect(decision.nextControl.lapPhase, LapPhase.sessionComplete);
    });

    test('allows restart from ENDED state after stop', () {
      final orchestrator = SessionOrchestrator();
      final ended = _baseControl(
        sessionState: SessionState.ended,
        lapsCompleted: 3,
      );

      final decision = orchestrator.requestStart(
        control: ended,
        speedKmh: 0.0,
        nowUtc: DateTime.now().toUtc(),
      );

      expect(decision.accepted, isTrue);
      expect(decision.nextControl.sessionState, SessionState.logging);
      expect(decision.nextControl.lapsCompleted, 0);
      expect(decision.nextControl.lapPhase, LapPhase.running);
    });

    test('session clock only advances while logging', () {
      final store = SessionControlStore();
      store.applyControlState(_baseControl(sessionState: SessionState.idle));
      store.sessionTimeSeconds = 10;
      store.advanceOneSecond();
      expect(store.sessionTimeSeconds, 10);

      store.applyControlState(_baseControl(sessionState: SessionState.armed));
      store.advanceOneSecond();
      expect(store.sessionTimeSeconds, 10);

      store.applyControlState(_baseControl(sessionState: SessionState.logging));
      store.advanceOneSecond();
      expect(store.sessionTimeSeconds, 11);

      store.applyControlState(_baseControl(sessionState: SessionState.ended));
      store.advanceOneSecond();
      expect(store.sessionTimeSeconds, 11);
    });
  });
}
