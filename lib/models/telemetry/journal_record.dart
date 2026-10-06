import 'dart:convert';
import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';

enum TelemetryRecordKind { metric, session }

class TelemetryRecord {
  final TelemetryRecordKind kind;
  final String sessionId;
  final int identityNumber;
  final String payloadJson;

  const TelemetryRecord({
    required this.kind,
    required this.sessionId,
    required this.identityNumber,
    required this.payloadJson,
  });

  factory TelemetryRecord.metric(DecodedMetricEvent event) => TelemetryRecord(
    kind: TelemetryRecordKind.metric,
    sessionId: event.sessionId,
    identityNumber: event.seqInSession,
    payloadJson: jsonEncode(event.toJson()),
  );

  factory TelemetryRecord.session(Map<String, dynamic> metadata) =>
      TelemetryRecord(
        kind: TelemetryRecordKind.session,
        sessionId: metadata['uid'] as String,
        identityNumber: metadata['metadata_revision'] as int,
        payloadJson: jsonEncode(metadata),
      );

  String get key => '${kind.name}/$sessionId/$identityNumber';
  Map<String, dynamic> get payload =>
      jsonDecode(payloadJson) as Map<String, dynamic>;
}

class PendingJournalRecord {
  final int id;
  final TelemetryRecord record;
  final DateTime enqueuedAtUtc;
  final int attempts;
  const PendingJournalRecord(
    this.id,
    this.record,
    this.enqueuedAtUtc,
    this.attempts,
  );
}
