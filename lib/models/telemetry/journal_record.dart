import 'dart:convert';
import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';

enum TelemetryRecordKind { metric, session }

class TelemetryRecord {
  final TelemetryRecordKind kind;
  final String sessionId;
  final int identityNumber;
  final String payloadJson;

  /// Control/diagnostic records (session metadata, lap, recovery and loss
  /// events) are small and define SQL session/lap structure, so they are
  /// exempt from the pending byte budget. Only capture metrics are shed.
  final bool control;

  const TelemetryRecord({
    required this.kind,
    required this.sessionId,
    required this.identityNumber,
    required this.payloadJson,
    bool control = false,
  }) : control = control || kind == TelemetryRecordKind.session;

  factory TelemetryRecord.metric(DecodedMetricEvent event) => TelemetryRecord(
    kind: TelemetryRecordKind.metric,
    sessionId: event.sessionId,
    identityNumber: event.seqInSession,
    payloadJson: jsonEncode(event.toJson()),
    control: event.sampleKind == 'diagnostic',
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

/// UTF-8 byte length of [value] without allocating the encoded bytes.
/// Matches `utf8.encode(value).length`, including lone surrogates (encoded as
/// U+FFFD, three bytes).
int utf8ByteLength(String value) {
  var bytes = 0;
  final length = value.length;
  for (var i = 0; i < length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < length &&
        (value.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

class PendingJournalRecord {
  final int id;
  final TelemetryRecord record;
  final DateTime enqueuedAtUtc;
  final int attempts;

  /// Stored UTF-8 size of [TelemetryRecord.payloadJson].
  final int payloadBytes;
  PendingJournalRecord(
    this.id,
    this.record,
    this.enqueuedAtUtc,
    this.attempts, {
    int? payloadBytes,
  }) : payloadBytes = payloadBytes ?? utf8ByteLength(record.payloadJson);
}
