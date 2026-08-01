enum UiMode { driver, service }

enum SessionState { idle, armed, logging, ended }

enum LapPhase {
  prestartCheck,
  running,
  crossingCandidate,
  crossingDeadzone,
  lapComplete,
  sessionComplete,
}

enum LapDividerMode { geofence, distance, none }

extension UiModeWire on UiMode {
  String get wireValue {
    switch (this) {
      case UiMode.driver:
        return 'DRIVER';
      case UiMode.service:
        return 'SERVICE';
    }
  }

  static UiMode fromWire(String value) {
    switch (value) {
      case 'DRIVER':
        return UiMode.driver;
      case 'SERVICE':
        return UiMode.service;
      default:
        throw ArgumentError('Unknown ui_mode: $value');
    }
  }
}

extension SessionStateWire on SessionState {
  String get wireValue {
    switch (this) {
      case SessionState.idle:
        return 'IDLE';
      case SessionState.armed:
        return 'ARMED';
      case SessionState.logging:
        return 'LOGGING';
      case SessionState.ended:
        return 'ENDED';
    }
  }

  static SessionState fromWire(String value) {
    switch (value) {
      case 'IDLE':
        return SessionState.idle;
      case 'ARMED':
        return SessionState.armed;
      case 'LOGGING':
        return SessionState.logging;
      case 'ENDED':
        return SessionState.ended;
      default:
        throw ArgumentError('Unknown session_state: $value');
    }
  }
}

extension LapPhaseWire on LapPhase {
  String get wireValue {
    switch (this) {
      case LapPhase.prestartCheck:
        return 'PRESTART_CHECK';
      case LapPhase.running:
        return 'RUNNING';
      case LapPhase.crossingCandidate:
        return 'CROSSING_CANDIDATE';
      case LapPhase.crossingDeadzone:
        return 'CROSSING_DEADZONE';
      case LapPhase.lapComplete:
        return 'LAP_COMPLETE';
      case LapPhase.sessionComplete:
        return 'SESSION_COMPLETE';
    }
  }

  static LapPhase fromWire(String value) {
    switch (value) {
      case 'PRESTART_CHECK':
        return LapPhase.prestartCheck;
      case 'RUNNING':
        return LapPhase.running;
      case 'CROSSING_CANDIDATE':
        return LapPhase.crossingCandidate;
      case 'CROSSING_DEADZONE':
        return LapPhase.crossingDeadzone;
      case 'LAP_COMPLETE':
        return LapPhase.lapComplete;
      case 'SESSION_COMPLETE':
        return LapPhase.sessionComplete;
      default:
        throw ArgumentError('Unknown lap_phase: $value');
    }
  }
}

extension LapDividerModeWire on LapDividerMode {
  String get wireValue {
    switch (this) {
      case LapDividerMode.geofence:
        return 'GEOFENCE';
      case LapDividerMode.distance:
        return 'DISTANCE';
      case LapDividerMode.none:
        return 'NONE';
    }
  }

  static LapDividerMode fromWire(String value) {
    switch (value) {
      case 'GEOFENCE':
        return LapDividerMode.geofence;
      case 'DISTANCE':
        return LapDividerMode.distance;
      case 'NONE':
        return LapDividerMode.none;
      default:
        return LapDividerMode.geofence;
    }
  }
}

class SessionControlState {
  final SessionState sessionState;
  final UiMode uiMode;
  final int lapsCompleted;
  final LapPhase lapPhase;
  final int crossingDeadzoneMs;
  final int crossingDeadzoneRemainingMs;
  final bool crossingValid;

  const SessionControlState({
    required this.sessionState,
    required this.uiMode,
    required this.lapsCompleted,
    required this.lapPhase,
    required this.crossingDeadzoneMs,
    required this.crossingDeadzoneRemainingMs,
    required this.crossingValid,
  });

  SessionControlState copyWith({
    SessionState? sessionState,
    UiMode? uiMode,
    int? lapsCompleted,
    LapPhase? lapPhase,
    int? crossingDeadzoneMs,
    int? crossingDeadzoneRemainingMs,
    bool? crossingValid,
  }) {
    return SessionControlState(
      sessionState: sessionState ?? this.sessionState,
      uiMode: uiMode ?? this.uiMode,
      lapsCompleted: lapsCompleted ?? this.lapsCompleted,
      lapPhase: lapPhase ?? this.lapPhase,
      crossingDeadzoneMs: crossingDeadzoneMs ?? this.crossingDeadzoneMs,
      crossingDeadzoneRemainingMs:
          crossingDeadzoneRemainingMs ?? this.crossingDeadzoneRemainingMs,
      crossingValid: crossingValid ?? this.crossingValid,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'session_state': sessionState.wireValue,
      'ui_mode': uiMode.wireValue,
      'laps_completed': lapsCompleted,
      'lap_phase': lapPhase.wireValue,
      'crossing_deadzone_ms': crossingDeadzoneMs,
      'crossing_deadzone_remaining_ms': crossingDeadzoneRemainingMs,
      'crossing_valid': crossingValid,
    };
  }

  factory SessionControlState.fromJson(Map<String, dynamic> json) {
    return SessionControlState(
      sessionState: SessionStateWire.fromWire(json['session_state'] as String),
      uiMode: UiModeWire.fromWire(json['ui_mode'] as String),
      lapsCompleted: (json['laps_completed'] as num).toInt(),
      lapPhase: LapPhaseWire.fromWire(json['lap_phase'] as String),
      crossingDeadzoneMs: (json['crossing_deadzone_ms'] as num).toInt(),
      crossingDeadzoneRemainingMs:
          (json['crossing_deadzone_remaining_ms'] as num).toInt(),
      crossingValid: json['crossing_valid'] as bool,
    );
  }
}

class SessionCheckpointSnapshot {
  final String sessionId;
  final String sessionName;
  final SessionState sessionState;
  final UiMode uiMode;
  final int lapsCompleted;
  final LapPhase lapPhase;
  final int crossingDeadzoneMs;
  final int crossingDeadzoneRemainingMs;
  final bool crossingValid;
  final int lapNumber;
  final int sessionTimeSeconds;
  final int lastSeqInSession;
  final bool gpsLocked;
  final bool usingPhoneGpsFallback;
  final LapDividerMode lapDividerMode;
  final double distanceLapDividerKm;
  final int gpsFallbackPeriodMs;
  final DateTime updatedAtUtc;

  const SessionCheckpointSnapshot({
    required this.sessionId,
    required this.sessionName,
    required this.sessionState,
    required this.uiMode,
    required this.lapsCompleted,
    required this.lapPhase,
    required this.crossingDeadzoneMs,
    required this.crossingDeadzoneRemainingMs,
    required this.crossingValid,
    required this.lapNumber,
    required this.sessionTimeSeconds,
    required this.lastSeqInSession,
    required this.gpsLocked,
    required this.usingPhoneGpsFallback,
    this.lapDividerMode = LapDividerMode.geofence,
    this.distanceLapDividerKm = 0.25,
    this.gpsFallbackPeriodMs = 5000,
    required this.updatedAtUtc,
  });

  SessionControlState get controlState {
    return SessionControlState(
      sessionState: sessionState,
      uiMode: uiMode,
      lapsCompleted: lapsCompleted,
      lapPhase: lapPhase,
      crossingDeadzoneMs: crossingDeadzoneMs,
      crossingDeadzoneRemainingMs: crossingDeadzoneRemainingMs,
      crossingValid: crossingValid,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'session_name': sessionName,
      'session_state': sessionState.wireValue,
      'ui_mode': uiMode.wireValue,
      'laps_completed': lapsCompleted,
      'lap_phase': lapPhase.wireValue,
      'crossing_deadzone_ms': crossingDeadzoneMs,
      'crossing_deadzone_remaining_ms': crossingDeadzoneRemainingMs,
      'crossing_valid': crossingValid,
      'lap_number': lapNumber,
      'session_time_seconds': sessionTimeSeconds,
      'last_seq_in_session': lastSeqInSession,
      'gps_locked': gpsLocked,
      'using_phone_gps_fallback': usingPhoneGpsFallback,
      'lap_divider_mode': lapDividerMode.wireValue,
      'distance_lap_divider_km': distanceLapDividerKm,
      'gps_fallback_period_ms': gpsFallbackPeriodMs,
      'updated_at_utc': updatedAtUtc.toUtc().toIso8601String(),
    };
  }

  factory SessionCheckpointSnapshot.fromJson(Map<String, dynamic> json) {
    return SessionCheckpointSnapshot(
      sessionId: json['session_id'] as String,
      sessionName: json['session_name'] as String? ?? '',
      sessionState: SessionStateWire.fromWire(json['session_state'] as String),
      uiMode: UiModeWire.fromWire(json['ui_mode'] as String),
      lapsCompleted: (json['laps_completed'] as num?)?.toInt() ?? 0,
      lapPhase: LapPhaseWire.fromWire(json['lap_phase'] as String),
      crossingDeadzoneMs:
          (json['crossing_deadzone_ms'] as num?)?.toInt() ?? 3000,
      crossingDeadzoneRemainingMs:
          (json['crossing_deadzone_remaining_ms'] as num?)?.toInt() ?? 0,
      crossingValid: json['crossing_valid'] as bool? ?? false,
      lapNumber: (json['lap_number'] as num?)?.toInt() ?? 1,
      sessionTimeSeconds: (json['session_time_seconds'] as num?)?.toInt() ?? 0,
      lastSeqInSession: (json['last_seq_in_session'] as num?)?.toInt() ?? 0,
      gpsLocked: json['gps_locked'] as bool? ?? false,
      usingPhoneGpsFallback: json['using_phone_gps_fallback'] as bool? ?? false,
      lapDividerMode: LapDividerModeWire.fromWire(
        json['lap_divider_mode'] as String? ?? 'GEOFENCE',
      ),
      distanceLapDividerKm:
          (json['distance_lap_divider_km'] as num?)?.toDouble() ?? 0.25,
      gpsFallbackPeriodMs:
          (json['gps_fallback_period_ms'] as num?)?.toInt() ?? 5000,
      updatedAtUtc:
          DateTime.tryParse(json['updated_at_utc'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}
