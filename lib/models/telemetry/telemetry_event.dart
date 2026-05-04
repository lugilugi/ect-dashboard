import 'package:telemetry_dashboard/models/session/session_models.dart';

class DecodedMetricEvent {
  final String metricKey;
  final double value;
  final String? unit;
  final String sessionId;
  final int? lapNumber;
  final SessionState sessionState;
  final LapPhase lapPhase;
  final DateTime tsWallUtc;
  final int tsSessionMs;
  final String source;
  final int? canId;
  final int seqInSession;
  final String? qualityFlag;
  final int? receivedAtUsMono;

  const DecodedMetricEvent({
    required this.metricKey,
    required this.value,
    this.unit,
    required this.sessionId,
    required this.lapNumber,
    required this.sessionState,
    required this.lapPhase,
    required this.tsWallUtc,
    required this.tsSessionMs,
    required this.source,
    this.canId,
    required this.seqInSession,
    this.qualityFlag,
    this.receivedAtUsMono,
  });

  Map<String, dynamic> toJson() {
    return {
      'metric_key': metricKey,
      'metric_value': value,
      if (unit != null) 'unit': unit,
      'session_id': sessionId,
      if (lapNumber != null) 'lap_number': lapNumber,
      'session_state': sessionState.wireValue,
      'lap_phase': lapPhase.wireValue,
      'ts_wall_utc': tsWallUtc.toUtc().toIso8601String(),
      'ts_session_ms': tsSessionMs,
      'source': source,
      if (canId != null) 'can_id': canId,
      'seq_in_session': seqInSession,
      if (qualityFlag != null) 'quality_flag': qualityFlag,
      if (receivedAtUsMono != null) 'received_at_us_mono': receivedAtUsMono,
    };
  }

  factory DecodedMetricEvent.fromJson(Map<String, dynamic> json) {
    final sessionStateWire = json['session_state'] as String? ?? 'LOGGING';
    final lapPhaseWire = json['lap_phase'] as String? ?? 'RUNNING';

    return DecodedMetricEvent(
      metricKey: json['metric_key'] as String,
      value: (json['metric_value'] as num).toDouble(),
      unit: json['unit'] as String?,
      sessionId: json['session_id'] as String,
      lapNumber: (json['lap_number'] as num?)?.toInt(),
      sessionState: SessionStateWire.fromWire(sessionStateWire),
      lapPhase: LapPhaseWire.fromWire(lapPhaseWire),
      tsWallUtc: DateTime.parse(json['ts_wall_utc'] as String).toUtc(),
      tsSessionMs: (json['ts_session_ms'] as num).toInt(),
      source: json['source'] as String,
      canId: (json['can_id'] as num?)?.toInt(),
      seqInSession: (json['seq_in_session'] as num).toInt(),
      qualityFlag: json['quality_flag'] as String?,
      receivedAtUsMono: (json['received_at_us_mono'] as num?)?.toInt(),
    );
  }
}

class LapCrossingEvent {
  final String sessionId;
  final int lapNumber;
  final DateTime tsWallUtc;
  final int tsSessionMs;
  final LapPhase lapPhase;
  final bool crossingValid;
  final String? reason;
  final double? confidence;
  final double? lat;
  final double? lon;
  final double? headingDeg;
  final double? speedKmh;

  const LapCrossingEvent({
    required this.sessionId,
    required this.lapNumber,
    required this.tsWallUtc,
    required this.tsSessionMs,
    required this.lapPhase,
    required this.crossingValid,
    this.reason,
    this.confidence,
    this.lat,
    this.lon,
    this.headingDeg,
    this.speedKmh,
  });

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'lap_number': lapNumber,
      'ts_wall_utc': tsWallUtc.toUtc().toIso8601String(),
      'ts_session_ms': tsSessionMs,
      'lap_phase': lapPhase.wireValue,
      'crossing_valid': crossingValid,
      if (reason != null) 'reason': reason,
      if (confidence != null) 'confidence': confidence,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (headingDeg != null) 'heading_deg': headingDeg,
      if (speedKmh != null) 'speed_kmh': speedKmh,
    };
  }

  factory LapCrossingEvent.fromJson(Map<String, dynamic> json) {
    return LapCrossingEvent(
      sessionId: json['session_id'] as String,
      lapNumber: (json['lap_number'] as num).toInt(),
      tsWallUtc: DateTime.parse(json['ts_wall_utc'] as String).toUtc(),
      tsSessionMs: (json['ts_session_ms'] as num).toInt(),
      lapPhase: LapPhaseWire.fromWire(json['lap_phase'] as String),
      crossingValid: json['crossing_valid'] as bool,
      reason: json['reason'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble(),
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
      headingDeg: (json['heading_deg'] as num?)?.toDouble(),
      speedKmh: (json['speed_kmh'] as num?)?.toDouble(),
    );
  }
}