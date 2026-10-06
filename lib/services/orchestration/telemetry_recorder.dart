import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';

class _Observation {
  final double value;
  final DateTime time;
  final String source;
  final String? unit;
  final int? canId;
  final String quality;
  final int freshnessMs;
  final String? sampleId;
  const _Observation(
    this.value,
    this.time,
    this.source,
    this.unit,
    this.canId,
    this.quality,
    this.freshnessMs,
    this.sampleId,
  );
}

/// Capture/sampling owns domain context; transport receives complete events.
class TelemetryRecorder {
  final DashboardState state;
  final DateTime Function() nowUtc;
  final TelemetryJournal? journal;
  final List<TelemetryRecord> _buffer = [];
  Timer? _commitTimer;
  Timer? _snapshotTimer;
  Timer? _retentionTimer;
  int _captureLosses = 0;
  Future<void>? _flushing;
  bool _started = false;
  String _metadataKey = '';
  int _completedLaps = 0;
  final Map<String, _Observation> _latest = {};
  String _sessionId = '';
  int _sequence = 0;

  TelemetryRecorder(this.state, {this.journal, DateTime Function()? nowUtc})
    : nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  int get sequence => _sequence;

  Future<void> start() async {
    if (_started) return;
    final storage = journal;
    if (storage != null) {
      await storage.initialize();
      final checkpoint = await storage.readCheckpoint();
      if (checkpoint != null) {
        // Corruption is surfaced; never silently discard the recovery record.
        final snapshot = SessionCheckpointSnapshot.fromJson(
          jsonDecode(checkpoint) as Map<String, dynamic>,
        );
        state.restoreFromCheckpoint(snapshot);
        state.metadataRevision = math.max(
          snapshot.metadataRevision,
          await storage.maxRevision(snapshot.sessionId),
        );
        restoreSequence(
          snapshot.sessionId,
          math.max(
            snapshot.lastSeqInSession,
            await storage.maxSequence(snapshot.sessionId),
          ),
        );
        _completedLaps = state.lapsCompleted;
        storage.spoolHealth.recordRecoveryResume();
        record(
          'Recovery_Resumed',
          1,
          source: 'app',
          unit: 'count',
          diagnostic: true,
        );
      }
    }
    _started = true;
    state.addListener(_captureMetadata);
    _captureMetadata();
    _commitTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_buffer.isNotEmpty) unawaited(_flushSafely());
    });
    _snapshotTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      sampleFreshValues();
      unawaited(_flushSafely());
    });
    _retentionTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(_maintainRetention());
    });
    await flush();
  }

  Future<void> _flushSafely() async {
    try {
      await flush();
    } catch (_) {
      /* Journal health exposes the failure. */
    }
  }

  void _enqueue(TelemetryRecord record, {bool control = false}) {
    if (journal == null) return;
    final capacity = record.kind == TelemetryRecordKind.session || control
        ? 256
        : 240;
    if (_buffer.length >= capacity) {
      _captureLosses++;
      journal!.spoolHealth.updateRecordingErrors(
        storage: 'Capture buffer full; recording loss',
        export: journal!.spoolHealth.exportError,
        rejected: 1,
      );
      return;
    }
    _buffer.add(record);
  }

  void _captureMetadata() {
    if (state.sessionId.isEmpty) return;
    final key = '${state.sessionId}/${state.metadataRevision}';
    if (key == _metadataKey) return;
    final changedSession = _sessionId != state.sessionId;
    _syncSession();
    if (changedSession) _completedLaps = 0;
    _metadataKey = key;
    for (var lap = _completedLaps + 1; lap <= state.lapsCompleted; lap++) {
      final crossing = state.lapCrossings
          .where((r) => r.lapNumber == lap)
          .firstOrNull;
      record(
        'Lap_Completed',
        lap.toDouble(),
        source: 'app',
        unit: 'count',
        diagnostic: true,
        lapNumber: lap,
        observedAtUtc: crossing?.tsWallUtc,
      );
    }
    _completedLaps = state.lapsCompleted;
    _enqueue(
      TelemetryRecord.session({
        'schema_version': 2,
        'uid': state.sessionId,
        'session_name': state.sessionName,
        'started_at_utc': (state.sessionStartedAtUtc ?? nowUtc())
            .toUtc()
            .toIso8601String(),
        'ended_at_utc': state.sessionEndedAtUtc?.toUtc().toIso8601String(),
        'session_state': state.sessionState.wireValue,
        'laps_completed': state.lapsCompleted,
        'metadata_revision': math.max(1, state.metadataRevision),
      }),
    );
  }

  Future<void> flush() =>
      _flushing ??= _commit().whenComplete(() => _flushing = null);

  Future<void> _commit() async {
    final storage = journal;
    if (storage == null) return;
    if (_captureLosses > 0 && _buffer.length < 256) {
      final losses = _captureLosses;
      _captureLosses = 0;
      record(
        'Recording_Loss',
        losses.toDouble(),
        source: 'app',
        unit: 'count',
        quality: 'invalid',
        diagnostic: true,
      );
    }
    final records = List<TelemetryRecord>.of(_buffer);
    final active =
        state.sessionState == SessionState.logging ||
        state.sessionState == SessionState.armed;
    final checkpoint = active
        ? jsonEncode(
            state
                .buildSessionCheckpointSnapshot(lastSeqInSession: _sequence)
                .toJson(),
          )
        : null;
    await storage.appendRecords(records, checkpointJson: checkpoint);
    _buffer.removeRange(0, records.length);
    unawaited(storage.flushExports().catchError((Object _) {}));
  }

  Future<void> stop() async {
    _started = false;
    _commitTimer?.cancel();
    _snapshotTimer?.cancel();
    _retentionTimer?.cancel();
    state.removeListener(_captureMetadata);
    await _flushing;
    await flush();
  }

  Future<void> _maintainRetention() async {
    final storage = journal;
    if (storage == null) return;
    try {
      await storage.flushExports();
      await storage.prune();
      await storage.pruneReadableCopyOlderThan(
        Duration(days: state.readableCopyRetentionDays),
      );
    } catch (error) {
      storage.spoolHealth.updateRecordingErrors(
        storage: storage.spoolHealth.storageError,
        export: error.toString(),
      );
    }
  }

  void restoreSequence(String sessionId, int sequence) {
    _sessionId = sessionId;
    _sequence = sequence;
    _latest.clear();
  }

  void _syncSession() {
    if (_sessionId == state.sessionId) return;
    _sessionId = state.sessionId;
    _sequence = 0;
    _latest.clear();
  }

  DecodedMetricEvent? record(
    String metric,
    double value, {
    DateTime? observedAtUtc,
    String source = 'can',
    String? unit,
    int? canId,
    String quality = 'ok',
    int freshnessMs = 5000,
    String? sourceSampleId,
    bool diagnostic = false,
    int? lapNumber,
  }) {
    _syncSession();
    if (_sessionId.isEmpty || (!state.isLogging && !diagnostic)) return null;
    if (!value.isFinite || metric.isEmpty || freshnessMs <= 0) return null;
    final observed = (observedAtUtc ?? nowUtc()).toUtc();
    final previous = _latest[metric];
    final observation = _Observation(
      value,
      observed,
      source,
      unit,
      canId,
      quality,
      freshnessMs,
      sourceSampleId,
    );
    if (!diagnostic) {
      // Suppressed unchanged observations still refresh source age.
      _latest[metric] = observation;
      if (previous != null &&
          previous.value == value &&
          previous.source == source &&
          previous.quality == quality &&
          previous.unit == unit &&
          previous.canId == canId &&
          previous.freshnessMs == freshnessMs &&
          previous.sampleId == sourceSampleId) {
        return null;
      }
    }
    return _event(
      metric,
      observation,
      observed,
      diagnostic ? 'diagnostic' : 'observation',
      lapNumber,
    );
  }

  List<DecodedMetricEvent> sampleFreshValues() {
    _syncSession();
    if (!state.isLogging) return const [];
    final now = nowUtc().toUtc();
    return [
      for (final entry in _latest.entries)
        if (entry.value.quality == 'ok' &&
            now.difference(entry.value.time).inMilliseconds >= 0 &&
            now.difference(entry.value.time).inMilliseconds <=
                entry.value.freshnessMs)
          _event(entry.key, entry.value, now, 'snapshot', null),
    ];
  }

  DecodedMetricEvent _event(
    String metric,
    _Observation observation,
    DateTime time,
    String kind,
    int? lapNumber,
  ) {
    final event = DecodedMetricEvent(
      metricKey: metric,
      value: observation.value,
      unit: observation.unit,
      sessionId: _sessionId,
      lapNumber: lapNumber ?? state.lapNumber,
      sessionState: state.sessionState,
      lapPhase: state.lapPhase,
      tsWallUtc: time,
      observedAtUtc: observation.time,
      tsSessionMs: state.sessionElapsedMs,
      source: observation.source,
      canId: observation.canId,
      seqInSession: ++_sequence,
      qualityFlag: observation.quality,
      sampleKind: kind,
      sourceSampleId: observation.sampleId,
      freshnessMs: observation.freshnessMs,
    );
    _enqueue(TelemetryRecord.metric(event), control: kind == 'diagnostic');
    return event;
  }
}
