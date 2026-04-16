import '../models/session_models.dart';
import '../models/telemetry_event.dart';

const int telemetryEventSchemaVersion = 1;

class TelemetryEventBatchPayload {
  final int schemaVersion;
  final String batchId;
  final String sessionId;
  final SessionState sessionState;
  final DateTime createdAtUtc;
  final int lapsPlanned;
  final int lapsCompleted;
  final List<DecodedMetricEvent> events;

  const TelemetryEventBatchPayload({
    required this.schemaVersion,
    required this.batchId,
    required this.sessionId,
    required this.sessionState,
    required this.createdAtUtc,
    required this.lapsPlanned,
    required this.lapsCompleted,
    required this.events,
  });

  factory TelemetryEventBatchPayload.singleEvent({
    required String batchId,
    required SessionControlState sessionControlState,
    required String sessionId,
    required DecodedMetricEvent event,
  }) {
    return TelemetryEventBatchPayload(
      schemaVersion: telemetryEventSchemaVersion,
      batchId: batchId,
      sessionId: sessionId,
      sessionState: sessionControlState.sessionState,
      createdAtUtc: DateTime.now().toUtc(),
      lapsPlanned: sessionControlState.lapsPlanned,
      lapsCompleted: sessionControlState.lapsCompleted,
      events: [event],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      'batch_id': batchId,
      'session_id': sessionId,
      'session_state': sessionState.wireValue,
      'created_at_utc': createdAtUtc.toUtc().toIso8601String(),
      'laps_planned': lapsPlanned,
      'laps_completed': lapsCompleted,
      'events': events.map((event) => event.toJson()).toList(),
    };
  }

  factory TelemetryEventBatchPayload.fromJson(Map<String, dynamic> json) {
    return TelemetryEventBatchPayload(
      schemaVersion: (json['schema_version'] as num).toInt(),
      batchId: json['batch_id'] as String,
      sessionId: json['session_id'] as String,
      sessionState: SessionStateWire.fromWire(json['session_state'] as String),
      createdAtUtc: DateTime.parse(json['created_at_utc'] as String).toUtc(),
      lapsPlanned: (json['laps_planned'] as num).toInt(),
      lapsCompleted: (json['laps_completed'] as num).toInt(),
      events: (json['events'] as List<dynamic>)
          .map((entry) => DecodedMetricEvent.fromJson(entry as Map<String, dynamic>))
          .toList(),
    );
  }
}