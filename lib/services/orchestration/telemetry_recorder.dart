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
///
/// The recorder is the journal's only writer. Capture appends to a bounded
/// in-memory queue that is committed by time ([commitInterval]) or earlier by
/// size ([commitThreshold]). Quota rejections are counted once and removed
/// from the queue, so recording resumes on its own when the sender drains the
/// backlog; only real storage errors keep the queue and retry with backoff.
class TelemetryRecorder {
  static const commitInterval = Duration(milliseconds: 200);
  static const commitThreshold = 250;

  /// One second of stalled storage at the 500 records/s peak, plus headroom.
  static const metricCapacity = 600;

  /// Session/control records may use reserved headroom above metrics.
  static const controlCapacity = 640;
  static const maxRetryDelay = Duration(seconds: 5);
  static const _lossSignal = 'Recording_Loss';

  final DashboardState state;
  final DateTime Function() nowUtc;
  final TelemetryJournal? journal;
  final List<TelemetryRecord> _buffer = [];
  Timer? _commitTimer;
  Timer? _snapshotTimer;
  Timer? _retentionTimer;
  bool _earlyCommitScheduled = false;

  /// Losses (capture overflow or quota) not yet carried by a queued
  /// Recording_Loss record.
  int _unreportedLosses = 0;

  /// Queued Recording_Loss records by journal key, with the count each carries.
  final Map<String, int> _lossRecords = {};
  Future<void>? _flushing;
  bool _started = false;
  String _metadataKey = '';
  int _completedLaps = 0;
  final Map<String, _Observation> _latest = {};
  String _sessionId = '';
  int _sequence = 0;
  final Stopwatch _clock = Stopwatch()..start();
  Duration _retryAt = Duration.zero;
  int _storageFailures = 0;
  bool _checkpointLoaded = false;
  String? _committedCheckpoint;
  int _appendCalls = 0;

  TelemetryRecorder(this.state, {this.journal, DateTime Function()? nowUtc})
    : nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  int get sequence => _sequence;
  int get bufferedRecordCount => _buffer.length;

  /// Journal append transactions attempted (diagnostics and tests).
  int get appendCalls => _appendCalls;

  Future<void> start() async {
    if (_started) return;
    final storage = journal;
    if (storage != null) {
      await storage.initialize();
      final checkpoint = await storage.readCheckpoint();
      _committedCheckpoint = checkpoint;
      _checkpointLoaded = true;
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
    _commitTimer = Timer.periodic(commitInterval, (_) {
      if (_buffer.isNotEmpty || _unreportedLosses > 0) {
        unawaited(_flushSafely());
      }
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

  /// Timer- or size-driven commit. Honors the storage-failure backoff;
  /// explicit [flush] calls do not.
  Future<void> _flushSafely() async {
    if (_clock.elapsed < _retryAt) return;
    try {
      await flush();
    } catch (_) {
      // appendRecords already published the storage error to spoolHealth;
      // the queue is kept and retried after the backoff.
    }
  }

  void _enqueue(TelemetryRecord record, {bool control = false}) {
    if (journal == null) return;
    final capacity = record.kind == TelemetryRecordKind.session || control
        ? controlCapacity
        : metricCapacity;
    if (_buffer.length >= capacity) {
      _unreportedLosses++;
      journal!.spoolHealth.updateRecordingErrors(
        storage: 'Capture buffer full; recording loss',
        export: journal!.spoolHealth.exportError,
        rejected: 1,
      );
      return;
    }
    _buffer.add(record);
    if (_started &&
        _buffer.length >= commitThreshold &&
        !_earlyCommitScheduled &&
        _flushing == null) {
      _earlyCommitScheduled = true;
      Timer.run(() {
        _earlyCommitScheduled = false;
        unawaited(_flushSafely());
      });
    }
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
    if (_unreportedLosses > 0 && _buffer.length < controlCapacity) {
      final losses = _unreportedLosses;
      _unreportedLosses = 0;
      final event = record(
        _lossSignal,
        losses.toDouble(),
        source: 'app',
        unit: 'count',
        quality: 'invalid',
        diagnostic: true,
      );
      if (event == null) {
        _unreportedLosses += losses;
      } else {
        final key =
            '${TelemetryRecordKind.metric.name}/'
            '${event.sessionId}/${event.seqInSession}';
        _lossRecords[key] = losses;
      }
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
    final checkpointChanged =
        !_checkpointLoaded ||
        !_sameCheckpoint(checkpoint, _committedCheckpoint);
    if (records.isEmpty && !checkpointChanged) return;
    final AppendResult result;
    try {
      _appendCalls++;
      result = await storage.appendRecords(
        records,
        checkpointJson: checkpoint,
        replaceCheckpoint: checkpointChanged,
      );
    } catch (_) {
      // Storage/I-O failure: nothing was committed. Keep the bounded queue
      // and retry with exponential backoff; capture beyond the bound is
      // counted as loss by _enqueue. The error itself is in spoolHealth.
      _storageFailures++;
      final delay = commitInterval * (1 << math.min(_storageFailures - 1, 5));
      _retryAt =
          _clock.elapsed + (delay > maxRetryDelay ? maxRetryDelay : delay);
      rethrow;
    }
    _storageFailures = 0;
    _retryAt = Duration.zero;
    if (checkpointChanged) {
      _committedCheckpoint = checkpoint;
      _checkpointLoaded = true;
    }
    // Every record of this batch reached a terminal outcome (stored,
    // duplicate, quota-rejected or moved to journal_failed).
    _buffer.removeRange(0, records.length);
    for (final key in result.quotaRejectedKeys) {
      // A rejected loss report carries its count forward instead of counting
      // as a new loss, so a full journal cannot generate a feedback loop.
      _unreportedLosses += _lossRecords[key] ?? 1;
    }
    for (final record in records) {
      if (record.kind == TelemetryRecordKind.metric) {
        _lossRecords.remove(record.key);
      }
    }
  }

  /// Compares checkpoints ignoring the volatile `updated_at_utc` stamp.
  static bool _sameCheckpoint(String? a, String? b) {
    if (a == null || b == null) return a == b;
    if (a == b) return true;
    try {
      final left = (jsonDecode(a) as Map<String, dynamic>)
        ..remove('updated_at_utc');
      final right = (jsonDecode(b) as Map<String, dynamic>)
        ..remove('updated_at_utc');
      return jsonEncode(left) == jsonEncode(right);
    } on FormatException {
      return false;
    }
  }

  Future<void> stop() async {
    _started = false;
    _commitTimer?.cancel();
    _snapshotTimer?.cancel();
    _retentionTimer?.cancel();
    state.removeListener(_captureMetadata);
    await _flushing;
    await flush();
    final storage = journal;
    if (storage == null) return;
    try {
      await storage.flushExports();
    } catch (_) {
      // _export recorded the failure in spoolHealth.exportError and kept its
      // cursor; the next export resumes from it.
    }
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
