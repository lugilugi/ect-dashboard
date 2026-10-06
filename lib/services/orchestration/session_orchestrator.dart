import 'package:telemetry_dashboard/models/session/session_models.dart';

class StartGateStatus {
  final bool ready;
  final int holdRemainingMs;

  const StartGateStatus({required this.ready, required this.holdRemainingMs});
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

  SessionControlState arm({required SessionControlState control}) {
    return control.copyWith(
      sessionState: SessionState.armed,
      uiMode: UiMode.driver,
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
        control.sessionState != SessionState.idle &&
        control.sessionState != SessionState.ended) {
      return SessionTransitionDecision(
        accepted: false,
        reason: 'Session can only start from IDLE, ARMED, or ENDED state.',
        nextControl: control,
        startGateStatus: gateStatus,
      );
    }

    // Logging may start regardless of vehicle motion. The gate status is
    // still returned for UI/telemetry purposes but never blocks the start.
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
    final nextLapsCompleted = control.lapsCompleted + 1;

    return control.copyWith(
      lapsCompleted: nextLapsCompleted,
      lapPhase: LapPhase.crossingDeadzone,
      crossingValid: true,
      crossingDeadzoneMs: deadzoneMs,
      crossingDeadzoneRemainingMs: deadzoneMs,
    );
  }
}

class SessionControlStore {
  final Stopwatch _clock = Stopwatch()..start();
  final int Function()? _monotonicMs;
  int _elapsedMs = 0;
  int _loggingStartedMs = 0;
  SessionControlStore({int Function()? monotonicMs})
    : _monotonicMs = monotonicMs;

  int get _nowMs => _monotonicMs?.call() ?? _clock.elapsedMilliseconds;
  int get elapsedMs =>
      _elapsedMs + (isLogging ? _nowMs - _loggingStartedMs : 0);
  set elapsedMs(int value) {
    _elapsedMs = value < 0 ? 0 : value;
    _loggingStartedMs = _nowMs;
  }

  UiMode uiMode = UiMode.driver;
  SessionState _sessionState = SessionState.idle;
  LapPhase lapPhase = LapPhase.prestartCheck;

  int lapsCompleted = 0;
  int crossingDeadzoneMs = 3000;
  int crossingDeadzoneRemainingMs = 0;
  bool crossingValid = false;
  int get sessionTimeSeconds => elapsedMs ~/ 1000;
  set sessionTimeSeconds(int value) => elapsedMs = value * 1000;

  SessionState get sessionState => _sessionState;

  bool get isLogging => _sessionState == SessionState.logging;

  void applyControlState(SessionControlState control) {
    if (isLogging) _elapsedMs = elapsedMs;
    _loggingStartedMs = _nowMs;
    lapsCompleted = control.lapsCompleted;
    crossingDeadzoneMs = control.crossingDeadzoneMs;
    crossingDeadzoneRemainingMs = control.crossingDeadzoneRemainingMs;
    crossingValid = control.crossingValid;
    uiMode = control.uiMode;
    lapPhase = control.lapPhase;
    _sessionState = control.sessionState;
  }

  void reset() {
    elapsedMs = 0;
    _sessionState = SessionState.idle;
    lapPhase = LapPhase.prestartCheck;
    lapsCompleted = 0;
    crossingValid = false;
    crossingDeadzoneRemainingMs = 0;
  }

  void advanceOneSecond() {
    if (crossingDeadzoneRemainingMs > 0) {
      crossingDeadzoneRemainingMs = (crossingDeadzoneRemainingMs - 1000)
          .clamp(0, crossingDeadzoneRemainingMs)
          .toInt();
      if (crossingDeadzoneRemainingMs == 0 &&
          lapPhase == LapPhase.crossingDeadzone) {
        lapPhase = LapPhase.running;
      }
    }
  }
}
