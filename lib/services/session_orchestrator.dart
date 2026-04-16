import '../models/session_models.dart';

class StartGateStatus {
  final bool ready;
  final int holdRemainingMs;

  const StartGateStatus({
    required this.ready,
    required this.holdRemainingMs,
  });
}

class SessionTransitionDecision {
  final bool accepted;
  final String? reason;
  final SessionControlState nextControl;
  final StartGateStatus startGateStatus;

  const SessionTransitionDecision({
    required this.accepted,
    required this.reason,
    required this.nextControl,
    required this.startGateStatus,
  });
}

class SessionOrchestrator {
  final double standstillThresholdKmh;
  final Duration standstillHold;

  DateTime? _standstillSinceUtc;

  SessionOrchestrator({
    this.standstillThresholdKmh = 0.5,
    this.standstillHold = const Duration(seconds: 1),
  }) {
    _standstillSinceUtc = DateTime.now().toUtc();
  }

  SessionControlState arm({
    required SessionControlState control,
    int? plannedLaps,
  }) {
    final resolvedPlannedLaps = plannedLaps == null || plannedLaps <= 0
        ? control.lapsPlanned
        : plannedLaps;

    return control.copyWith(
      sessionState: SessionState.armed,
      uiMode: UiMode.driver,
      lapsPlanned: resolvedPlannedLaps,
      lapsCompleted: 0,
      lapPhase: LapPhase.prestartCheck,
      crossingValid: false,
      crossingDeadzoneRemainingMs: 0,
    );
  }

  StartGateStatus evaluateStartGate({
    required double speedKmh,
    required DateTime nowUtc,
  }) {
    if (speedKmh <= standstillThresholdKmh) {
      _standstillSinceUtc ??= nowUtc;
    } else {
      _standstillSinceUtc = null;
    }

    if (_standstillSinceUtc == null) {
      return StartGateStatus(
        ready: false,
        holdRemainingMs: standstillHold.inMilliseconds,
      );
    }

    final elapsed = nowUtc.difference(_standstillSinceUtc!);
    final remaining = standstillHold - elapsed;
    if (remaining <= Duration.zero) {
      return const StartGateStatus(ready: true, holdRemainingMs: 0);
    }

    return StartGateStatus(
      ready: false,
      holdRemainingMs: remaining.inMilliseconds,
    );
  }

  SessionTransitionDecision requestStart({
    required SessionControlState control,
    required double speedKmh,
    required DateTime nowUtc,
  }) {
    final gateStatus = evaluateStartGate(speedKmh: speedKmh, nowUtc: nowUtc);

    if (control.sessionState != SessionState.armed &&
        control.sessionState != SessionState.idle) {
      return SessionTransitionDecision(
        accepted: false,
        reason: 'Session can only start from IDLE or ARMED state.',
        nextControl: control,
        startGateStatus: gateStatus,
      );
    }

    if (!gateStatus.ready) {
      return SessionTransitionDecision(
        accepted: false,
        reason: 'Start blocked until standstill hold window is satisfied.',
        nextControl: control,
        startGateStatus: gateStatus,
      );
    }

    return SessionTransitionDecision(
      accepted: true,
      reason: null,
      nextControl: control.copyWith(
        sessionState: SessionState.logging,
        uiMode: UiMode.driver,
        lapPhase: LapPhase.running,
        lapsCompleted: 0,
        crossingValid: false,
        crossingDeadzoneRemainingMs: 0,
      ),
      startGateStatus: gateStatus,
    );
  }

  SessionTransitionDecision requestStop({
    required SessionControlState control,
    required DateTime nowUtc,
    bool abort = false,
    bool enforceLapTarget = true,
  }) {
    final gateStatus = evaluateStartGate(speedKmh: 0, nowUtc: nowUtc);

    if (control.sessionState != SessionState.logging && !abort) {
      return SessionTransitionDecision(
        accepted: false,
        reason: 'Session can only stop from LOGGING state.',
        nextControl: control,
        startGateStatus: gateStatus,
      );
    }

    if (!abort &&
        enforceLapTarget &&
        control.lapsCompleted < control.lapsPlanned) {
      return SessionTransitionDecision(
        accepted: false,
        reason:
            'End blocked until lapsCompleted >= lapsPlanned (or abort is used).',
        nextControl: control,
        startGateStatus: gateStatus,
      );
    }

    return SessionTransitionDecision(
      accepted: true,
      reason: null,
      nextControl: control.copyWith(
        sessionState: SessionState.ended,
        lapPhase: LapPhase.sessionComplete,
        crossingDeadzoneRemainingMs: 0,
      ),
      startGateStatus: gateStatus,
    );
  }

  SessionControlState applyLapAccepted({
    required SessionControlState control,
    required int deadzoneMs,
  }) {
    final nextLapsCompleted = (control.lapsCompleted + 1).clamp(
      0,
      control.lapsPlanned,
    );

    return control.copyWith(
      lapsCompleted: nextLapsCompleted,
      lapPhase: LapPhase.crossingDeadzone,
      crossingValid: true,
      crossingDeadzoneMs: deadzoneMs,
      crossingDeadzoneRemainingMs: deadzoneMs,
    );
  }
}