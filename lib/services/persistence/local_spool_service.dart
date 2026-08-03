import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import 'package:telemetry_dashboard/services/persistence/readable_local_copy_writer.dart';

class SpoolBatchRecord {
  final int id;
  final String topic;
  final String payloadJson;
  final DateTime enqueuedAtUtc;
  final String? sessionId;
  final int? seqInSessionStart;
  final int? seqInSessionEnd;
  final int attemptCount;
  final DateTime? lastAttemptAtUtc;
  final DateTime? publishedAtUtc;

  const SpoolBatchRecord({
    required this.id,
    required this.topic,
    required this.payloadJson,
    required this.enqueuedAtUtc,
    required this.sessionId,
    required this.seqInSessionStart,
    required this.seqInSessionEnd,
    required this.attemptCount,
    required this.lastAttemptAtUtc,
    required this.publishedAtUtc,
  });

  bool get isPending => publishedAtUtc == null;

  SpoolBatchRecord copyWith({
    int? id,
    String? topic,
    String? payloadJson,
    DateTime? enqueuedAtUtc,
    String? sessionId,
    int? seqInSessionStart,
    int? seqInSessionEnd,
    int? attemptCount,
    DateTime? lastAttemptAtUtc,
    DateTime? publishedAtUtc,
  }) {
    return SpoolBatchRecord(
      id: id ?? this.id,
      topic: topic ?? this.topic,
      payloadJson: payloadJson ?? this.payloadJson,
      enqueuedAtUtc: enqueuedAtUtc ?? this.enqueuedAtUtc,
      sessionId: sessionId ?? this.sessionId,
      seqInSessionStart: seqInSessionStart ?? this.seqInSessionStart,
      seqInSessionEnd: seqInSessionEnd ?? this.seqInSessionEnd,
      attemptCount: attemptCount ?? this.attemptCount,
      lastAttemptAtUtc: lastAttemptAtUtc ?? this.lastAttemptAtUtc,
      publishedAtUtc: publishedAtUtc ?? this.publishedAtUtc,
    );
  }

  factory SpoolBatchRecord.fromRow(Map<String, Object?> row) {
    return SpoolBatchRecord(
      id: (row['id'] as num).toInt(),
      topic: row['topic'] as String,
      payloadJson: row['payload_json'] as String,
      enqueuedAtUtc: DateTime.parse(row['enqueued_at_utc'] as String).toUtc(),
      sessionId: row['session_id'] as String?,
      seqInSessionStart: (row['seq_in_session_start'] as num?)?.toInt(),
      seqInSessionEnd: (row['seq_in_session_end'] as num?)?.toInt(),
      attemptCount: (row['attempt_count'] as num? ?? 0).toInt(),
      lastAttemptAtUtc: (row['last_attempt_at_utc'] as String?) == null
          ? null
          : DateTime.parse(row['last_attempt_at_utc'] as String).toUtc(),
      publishedAtUtc: (row['published_at_utc'] as String?) == null
          ? null
          : DateTime.parse(row['published_at_utc'] as String).toUtc(),
    );
  }
}

class SpoolDecodedEventRecord {
  final int id;
  final String sessionId;
  final int seqInSession;
  final String eventJson;
  final DateTime enqueuedAtUtc;
  final DateTime? publishedAtUtc;

  const SpoolDecodedEventRecord({
    required this.id,
    required this.sessionId,
    required this.seqInSession,
    required this.eventJson,
    required this.enqueuedAtUtc,
    required this.publishedAtUtc,
  });

  bool get isPending => publishedAtUtc == null;

  SpoolDecodedEventRecord copyWith({
    int? id,
    String? sessionId,
    int? seqInSession,
    String? eventJson,
    DateTime? enqueuedAtUtc,
    DateTime? publishedAtUtc,
  }) {
    return SpoolDecodedEventRecord(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      seqInSession: seqInSession ?? this.seqInSession,
      eventJson: eventJson ?? this.eventJson,
      enqueuedAtUtc: enqueuedAtUtc ?? this.enqueuedAtUtc,
      publishedAtUtc: publishedAtUtc ?? this.publishedAtUtc,
    );
  }

  factory SpoolDecodedEventRecord.fromRow(Map<String, Object?> row) {
    return SpoolDecodedEventRecord(
      id: (row['id'] as num).toInt(),
      sessionId: row['session_id'] as String,
      seqInSession: (row['seq_in_session'] as num).toInt(),
      eventJson: row['event_json'] as String,
      enqueuedAtUtc: DateTime.parse(row['enqueued_at_utc'] as String).toUtc(),
      publishedAtUtc: (row['published_at_utc'] as String?) == null
          ? null
          : DateTime.parse(row['published_at_utc'] as String).toUtc(),
    );
  }
}

class SpoolHealthStore extends ChangeNotifier {
  int _pendingPublishCount = 0;
  DateTime? _oldestEnqueuedAtUtc;
  int _oldestAgeMs = 0;
  int _pendingBatchCount = 0;
  int _pendingBatchCapacity = 0;
  bool _capacityWarning = false;
  int _recoveryResumeCount = 0;
  DateTime? _lastRecoveryAtUtc;
  bool _requiresReplayDrainBeforeStop = false;
  Timer? _ageTicker;

  int get pendingPublishCount => _pendingPublishCount;
  DateTime? get oldestEnqueuedAtUtc => _oldestEnqueuedAtUtc;
  int get oldestAgeMs => _oldestAgeMs;
  int get pendingBatchCount => _pendingBatchCount;
  int get pendingBatchCapacity => _pendingBatchCapacity;
  bool get capacityWarning => _capacityWarning;
  int get recoveryResumeCount => _recoveryResumeCount;
  DateTime? get lastRecoveryAtUtc => _lastRecoveryAtUtc;
  bool get requiresReplayDrainBeforeStop => _requiresReplayDrainBeforeStop;

  void updateBacklog({
    required int count,
    required DateTime? oldestEnqueuedAtUtc,
  }) {
    final sanitizedCount = count < 0 ? 0 : count;
    final nextOldest = sanitizedCount > 0 ? oldestEnqueuedAtUtc : null;
    final nextAgeMs = nextOldest == null
        ? 0
        : DateTime.now().toUtc().difference(nextOldest).inMilliseconds;

    var changed =
        _pendingPublishCount != sanitizedCount ||
        _oldestEnqueuedAtUtc != nextOldest ||
        _oldestAgeMs != nextAgeMs;

    _pendingPublishCount = sanitizedCount;
    _oldestEnqueuedAtUtc = nextOldest;
    _oldestAgeMs = nextAgeMs;

    if (_requiresReplayDrainBeforeStop && sanitizedCount == 0) {
      _requiresReplayDrainBeforeStop = false;
      changed = true;
    }

    _syncTicker();

    if (changed) {
      notifyListeners();
    }
  }

  void updatePendingCapacity({
    required int pendingBatchCount,
    required int pendingBatchCapacity,
  }) {
    final sanitizedPending = pendingBatchCount < 0 ? 0 : pendingBatchCount;
    final sanitizedCapacity = pendingBatchCapacity < 0
        ? 0
        : pendingBatchCapacity;
    final warningThreshold = sanitizedCapacity <= 0
        ? 0
        : ((sanitizedCapacity * 0.8).ceil());
    final warning =
        sanitizedCapacity > 0 && sanitizedPending >= warningThreshold;

    final changed =
        _pendingBatchCount != sanitizedPending ||
        _pendingBatchCapacity != sanitizedCapacity ||
        _capacityWarning != warning;

    _pendingBatchCount = sanitizedPending;
    _pendingBatchCapacity = sanitizedCapacity;
    _capacityWarning = warning;

    if (changed) {
      notifyListeners();
    }
  }

  void recordRecoveryResume({DateTime? atUtc}) {
    _recoveryResumeCount += 1;
    _requiresReplayDrainBeforeStop = true;
    _lastRecoveryAtUtc = (atUtc ?? DateTime.now().toUtc()).toUtc();
    notifyListeners();
  }

  void clearReplayDrainGate() {
    if (!_requiresReplayDrainBeforeStop) {
      return;
    }
    _requiresReplayDrainBeforeStop = false;
    notifyListeners();
  }

  void _syncTicker() {
    if (_pendingPublishCount > 0 && _oldestEnqueuedAtUtc != null) {
      _startTicker();
    } else {
      _stopTicker();
      if (_oldestAgeMs != 0) {
        _oldestAgeMs = 0;
      }
    }
  }

  void _startTicker() {
    if (_ageTicker != null) {
      return;
    }
    _ageTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final oldest = _oldestEnqueuedAtUtc;
      if (oldest == null || _pendingPublishCount <= 0) {
        _stopTicker();
        return;
      }

      final nextAge = DateTime.now().toUtc().difference(oldest).inMilliseconds;
      if (nextAge != _oldestAgeMs) {
        _oldestAgeMs = nextAge;
        notifyListeners();
      }
    });
  }

  void _stopTicker() {
    _ageTicker?.cancel();
    _ageTicker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }
}

/// Persists telemetry locally.
///
/// - SQLite spool: holds MQTT payloads that have not reached the server yet
///   (replayed on reconnect) plus crash-recovery session checkpoints and a
///   deduplicated event log that keeps per-session sequence watermarks.
/// - CSV output: every decoded telemetry event is appended to one CSV file per
///   session, ready to open in any spreadsheet app.
class LocalSpoolService {
  static const String _dbName = 'edge_spool.db';
  static const String _batchesTable = 'publish_batches';
  static const String _decodedEventsTable = 'decoded_events';
  static const String _checkpointsTable = 'session_checkpoints';

  final int maxPendingBatches;
  final bool forceInMemory;
  final bool readableCopyEnabled;
  final String? readableCopyDirectoryPath;
  final int readableCopyMaxFileBytes;

  final ReadableLocalCopyWriter _readableCopyWriter;
  final SpoolHealthStore spoolHealth = SpoolHealthStore();

  static bool _ffiDatabaseFactoryConfigured = false;

  Database? _db;
  bool _initialized = false;
  bool _usingMemoryFallback = false;
  int _nextMemoryId = 1;
  int _nextMemoryDecodedEventId = 1;
  Timer? _csvFlushTimer;
  Timer? _decodedEventFlushTimer;
  final List<Map<String, Object?>> _decodedEventBatch =
      <Map<String, Object?>>[];
  bool _flushingDecodedBatch = false;
  static const int _decodedEventBatchThreshold = 100;
  final List<SpoolBatchRecord> _memoryRecords = <SpoolBatchRecord>[];
  final List<SpoolDecodedEventRecord> _memoryDecodedEvents =
      <SpoolDecodedEventRecord>[];
  String? _memorySessionCheckpointJson;

  LocalSpoolService({
    this.maxPendingBatches = 50000,
    this.forceInMemory = false,
    this.readableCopyEnabled = true,
    this.readableCopyDirectoryPath,
    this.readableCopyMaxFileBytes = 4 * 1024 * 1024,
    ReadableLocalCopyWriter? readableCopyWriter,
  }) : _readableCopyWriter =
           readableCopyWriter ??
           ReadableLocalCopyWriter(maxFileBytes: readableCopyMaxFileBytes);

  String? get readableCopyPath => _readableCopyWriter.directoryPath;
  String? get sessionCsvPath => _readableCopyWriter.sessionCsvDirectoryPath;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _initialized = true;
    String? dbPath;

    if (forceInMemory) {
      _usingMemoryFallback = true;
    } else {
      try {
        _ensureDesktopDatabaseFactory();
        dbPath = await getDatabasesPath();
        final fullPath = p.join(dbPath, _dbName);

        _db = await openDatabase(
          fullPath,
          version: 3,
          onCreate: (db, version) async {
            await db.execute('''
            CREATE TABLE $_batchesTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              topic TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              enqueued_at_utc TEXT NOT NULL,
              session_id TEXT,
              seq_in_session_start INTEGER,
              seq_in_session_end INTEGER,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              last_attempt_at_utc TEXT,
              published_at_utc TEXT
            )
          ''');
            await db.execute('''
            CREATE TABLE $_decodedEventsTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              seq_in_session INTEGER NOT NULL,
              event_json TEXT NOT NULL,
              enqueued_at_utc TEXT NOT NULL,
              published_at_utc TEXT,
              UNIQUE(session_id, seq_in_session)
            )
          ''');
            await db.execute('''
            CREATE TABLE $_checkpointsTable (
              id INTEGER PRIMARY KEY CHECK(id = 1),
              checkpoint_json TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL
            )
          ''');
            await db.execute(
              'CREATE INDEX idx_batches_pending ON $_batchesTable(published_at_utc, enqueued_at_utc)',
            );
            await db.execute(
              'CREATE INDEX idx_decoded_pending ON $_decodedEventsTable(published_at_utc, enqueued_at_utc)',
            );
            await db.execute(
              'CREATE INDEX idx_decoded_session_seq ON $_decodedEventsTable(session_id, seq_in_session)',
            );
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 2) {
              await db.execute('''
              CREATE TABLE IF NOT EXISTS $_checkpointsTable (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                checkpoint_json TEXT NOT NULL,
                updated_at_utc TEXT NOT NULL
              )
            ''');
            }
            if (oldVersion < 3) {
              // Version 3 dropped the unused audit/sink tables.
              await db.execute('DROP TABLE IF EXISTS publish_attempts');
              await db.execute('DROP TABLE IF EXISTS raw_frames');
            }
          },
        );

        _usingMemoryFallback = false;
      } on MissingPluginException catch (_) {
        _usingMemoryFallback = true;
        debugPrint(
          'LocalSpoolService falling back to in-memory backend: sqflite plugin unavailable on this platform.',
        );
      } catch (e) {
        _usingMemoryFallback = true;
        debugPrint(
          'LocalSpoolService using in-memory backend due to init error: $e',
        );
      }
    }

    if (readableCopyEnabled) {
      _readableCopyWriter.setMaxFileBytes(readableCopyMaxFileBytes);
      await _readableCopyWriter.initialize(
        baseDirectoryPath: dbPath,
        overrideDirectoryPath: readableCopyDirectoryPath,
      );
    }

    _csvFlushTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_readableCopyWriter.flush());
    });
    _decodedEventFlushTimer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        unawaited(_flushDecodedEventBatch());
      },
    );
  }

  void _ensureDesktopDatabaseFactory() {
    if (kIsWeb || _ffiDatabaseFactoryConfigured) {
      return;
    }

    final platform = defaultTargetPlatform;
    final isDesktop =
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;

    if (!isDesktop) {
      return;
    }

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _ffiDatabaseFactoryConfigured = true;
  }

  Future<int> enqueueBatch({
    required String topic,
    required String payloadJson,
    DateTime? enqueuedAtUtc,
    String? sessionId,
    int? seqInSessionStart,
    int? seqInSessionEnd,
  }) async {
    await initialize();
    final enqueued = (enqueuedAtUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      final record = SpoolBatchRecord(
        id: _nextMemoryId++,
        topic: topic,
        payloadJson: payloadJson,
        enqueuedAtUtc: enqueued,
        sessionId: sessionId,
        seqInSessionStart: seqInSessionStart,
        seqInSessionEnd: seqInSessionEnd,
        attemptCount: 0,
        lastAttemptAtUtc: null,
        publishedAtUtc: null,
      );
      _memoryRecords.add(record);
      await _trimMemoryPendingToCap();
      return record.id;
    }

    final id = await _db!.insert(_batchesTable, <String, Object?>{
      'topic': topic,
      'payload_json': payloadJson,
      'enqueued_at_utc': enqueued.toIso8601String(),
      'session_id': sessionId,
      'seq_in_session_start': seqInSessionStart,
      'seq_in_session_end': seqInSessionEnd,
    });
    await _trimDbPendingToCap();
    return id;
  }

  Future<List<SpoolBatchRecord>> readPendingBatches({int limit = 500}) async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      final pending = _memoryRecords
          .where((record) => record.isPending)
          .toList();
      pending.sort((a, b) => a.enqueuedAtUtc.compareTo(b.enqueuedAtUtc));
      return pending.take(limit).toList();
    }

    final rows = await _db!.query(
      _batchesTable,
      where: 'published_at_utc IS NULL',
      orderBy: 'enqueued_at_utc ASC',
      limit: limit,
    );
    return rows.map(SpoolBatchRecord.fromRow).toList(growable: false);
  }

  Future<void> enqueueDecodedEvent({
    required String sessionId,
    required int seqInSession,
    required String eventJson,
    DateTime? enqueuedAtUtc,
  }) async {
    await initialize();
    final enqueued = (enqueuedAtUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      final existingIndex = _memoryDecodedEvents.indexWhere(
        (record) =>
            record.sessionId == sessionId &&
            record.seqInSession == seqInSession,
      );
      if (existingIndex != -1) {
        return;
      }

      _memoryDecodedEvents.add(
        SpoolDecodedEventRecord(
          id: _nextMemoryDecodedEventId++,
          sessionId: sessionId,
          seqInSession: seqInSession,
          eventJson: eventJson,
          enqueuedAtUtc: enqueued,
          publishedAtUtc: null,
        ),
      );
      await _appendSessionCsvEvent(
        sessionId: sessionId,
        seqInSession: seqInSession,
        eventJson: eventJson,
      );
      return;
    }

    _decodedEventBatch.add(<String, Object?>{
      'session_id': sessionId,
      'seq_in_session': seqInSession,
      'event_json': eventJson,
      'enqueued_at_utc': enqueued.toIso8601String(),
    });
    if (_decodedEventBatch.length >= _decodedEventBatchThreshold) {
      unawaited(_flushDecodedEventBatch());
    }
    await _appendSessionCsvEvent(
      sessionId: sessionId,
      seqInSession: seqInSession,
      eventJson: eventJson,
    );
  }

  @visibleForTesting
  Future<int> pendingDecodedEventCount() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      return _memoryDecodedEvents.where((record) => record.isPending).length;
    }

    await _flushDecodedEventBatch();
    final rows = await _db!.rawQuery(
      'SELECT COUNT(*) AS count FROM $_decodedEventsTable WHERE published_at_utc IS NULL',
    );
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<int> maxDecodedSequenceForSession(String sessionId) async {
    await initialize();

    if (sessionId.isEmpty) {
      return 0;
    }

    if (_usingMemoryFallback || _db == null) {
      int maxSeq = 0;
      for (final record in _memoryDecodedEvents) {
        if (record.sessionId != sessionId) {
          continue;
        }
        if (record.seqInSession > maxSeq) {
          maxSeq = record.seqInSession;
        }
      }
      return maxSeq;
    }

    await _flushDecodedEventBatch();
    final rows = await _db!.rawQuery(
      'SELECT MAX(seq_in_session) AS max_seq FROM $_decodedEventsTable WHERE session_id = ?',
      <Object?>[sessionId],
    );
    return (rows.first['max_seq'] as num?)?.toInt() ?? 0;
  }

  Future<void> markDecodedEventsPublishedRange({
    required String sessionId,
    required int seqInSessionStart,
    required int seqInSessionEnd,
    DateTime? publishedAtUtc,
  }) async {
    if (seqInSessionEnd < seqInSessionStart) {
      return;
    }

    await initialize();
    final published = (publishedAtUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      for (int i = 0; i < _memoryDecodedEvents.length; i++) {
        final record = _memoryDecodedEvents[i];
        if (!record.isPending) {
          continue;
        }
        if (record.sessionId != sessionId) {
          continue;
        }
        if (record.seqInSession < seqInSessionStart ||
            record.seqInSession > seqInSessionEnd) {
          continue;
        }

        _memoryDecodedEvents[i] = record.copyWith(publishedAtUtc: published);
      }
      return;
    }

    await _flushDecodedEventBatch();
    await _db!.rawUpdate(
      'UPDATE $_decodedEventsTable SET published_at_utc = ? WHERE session_id = ? AND seq_in_session BETWEEN ? AND ? AND published_at_utc IS NULL',
      <Object?>[
        published.toIso8601String(),
        sessionId,
        seqInSessionStart,
        seqInSessionEnd,
      ],
    );
  }

  Future<void> recordAttempt({
    required int batchId,
    required String outcome,
    String? errorReason,
    DateTime? attemptedAtUtc,
    bool incrementAttemptCounter = true,
  }) async {
    await initialize();
    final attempted = (attemptedAtUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      final index = _memoryRecords.indexWhere((record) => record.id == batchId);
      if (index != -1) {
        final existing = _memoryRecords[index];
        _memoryRecords[index] = existing.copyWith(
          attemptCount: incrementAttemptCounter
              ? existing.attemptCount + 1
              : existing.attemptCount,
          lastAttemptAtUtc: attempted,
        );
      }
      return;
    }

    if (incrementAttemptCounter) {
      await _db!.rawUpdate(
        'UPDATE $_batchesTable SET attempt_count = attempt_count + 1, last_attempt_at_utc = ? WHERE id = ?',
        <Object?>[attempted.toIso8601String(), batchId],
      );
    } else {
      await _db!.rawUpdate(
        'UPDATE $_batchesTable SET last_attempt_at_utc = ? WHERE id = ?',
        <Object?>[attempted.toIso8601String(), batchId],
      );
    }
  }

  Future<void> markPublished({
    required int batchId,
    DateTime? publishedAtUtc,
  }) async {
    await initialize();
    final published = (publishedAtUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      final index = _memoryRecords.indexWhere((record) => record.id == batchId);
      if (index != -1) {
        _memoryRecords[index] = _memoryRecords[index].copyWith(
          publishedAtUtc: published,
        );
      }
      return;
    }

    await _db!.update(
      _batchesTable,
      <String, Object?>{'published_at_utc': published.toIso8601String()},
      where: 'id = ?',
      whereArgs: <Object?>[batchId],
    );
  }

  Future<int> pendingCount() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      return _memoryRecords.where((record) => record.isPending).length;
    }

    final rows = await _db!.rawQuery(
      'SELECT COUNT(*) AS count FROM $_batchesTable WHERE published_at_utc IS NULL',
    );
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  @visibleForTesting
  Future<DateTime?> oldestPendingEnqueuedAtUtc() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      final pending = _memoryRecords
          .where((record) => record.isPending)
          .toList();
      if (pending.isEmpty) {
        return null;
      }
      pending.sort((a, b) => a.enqueuedAtUtc.compareTo(b.enqueuedAtUtc));
      return pending.first.enqueuedAtUtc;
    }

    final rows = await _db!.query(
      _batchesTable,
      columns: <String>['enqueued_at_utc'],
      where: 'published_at_utc IS NULL',
      orderBy: 'enqueued_at_utc ASC',
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return DateTime.parse(rows.first['enqueued_at_utc'] as String).toUtc();
  }

  Future<void> saveSessionCheckpoint({
    required String checkpointJson,
    DateTime? updatedAtUtc,
  }) async {
    await initialize();
    final updatedAt = (updatedAtUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      _memorySessionCheckpointJson = checkpointJson;
      return;
    }

    await _db!.insert(_checkpointsTable, <String, Object?>{
      'id': 1,
      'checkpoint_json': checkpointJson,
      'updated_at_utc': updatedAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> readSessionCheckpointJson() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      return _memorySessionCheckpointJson;
    }

    final rows = await _db!.query(
      _checkpointsTable,
      columns: <String>['checkpoint_json'],
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['checkpoint_json'] as String?;
  }

  Future<void> clearSessionCheckpoint() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      _memorySessionCheckpointJson = null;
      return;
    }

    await _db!.delete(_checkpointsTable, where: 'id = 1');
  }

  Future<void> prunePublishedOlderThan(Duration maxAge) async {
    await initialize();
    final cutoff = DateTime.now().toUtc().subtract(maxAge);

    if (_usingMemoryFallback || _db == null) {
      _memoryRecords.removeWhere(
        (record) =>
            record.publishedAtUtc != null &&
            record.publishedAtUtc!.isBefore(cutoff),
      );
      return;
    }

    await _db!.delete(
      _batchesTable,
      where: 'published_at_utc IS NOT NULL AND published_at_utc < ?',
      whereArgs: <Object?>[cutoff.toIso8601String()],
    );
  }

  Future<void> prunePublishedDecodedEventsOlderThan(Duration maxAge) async {
    await initialize();
    final cutoff = DateTime.now().toUtc().subtract(maxAge);

    if (_usingMemoryFallback || _db == null) {
      _memoryDecodedEvents.removeWhere(
        (record) =>
            record.publishedAtUtc != null &&
            record.publishedAtUtc!.isBefore(cutoff),
      );
      return;
    }

    await _flushDecodedEventBatch();
    await _db!.delete(
      _decodedEventsTable,
      where: 'published_at_utc IS NOT NULL AND published_at_utc < ?',
      whereArgs: <Object?>[cutoff.toIso8601String()],
    );
  }

  Future<void> pruneReadableCopyOlderThan(Duration maxAge) async {
    await initialize();
    if (!readableCopyEnabled) {
      return;
    }
    await _readableCopyWriter.pruneOlderThan(maxAge);
  }

  Future<void> clearSpoolBatches() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      _memoryRecords.clear();
      _nextMemoryId = 1;
    } else {
      await _db!.delete(_batchesTable);
    }

    spoolHealth.updateBacklog(count: 0, oldestEnqueuedAtUtc: null);
    spoolHealth.updatePendingCapacity(
      pendingBatchCount: 0,
      pendingBatchCapacity: maxPendingBatches,
    );
  }

  Future<void> clearDecodedEvents() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      _memoryDecodedEvents.clear();
      _nextMemoryDecodedEventId = 1;
    } else {
      await _flushDecodedEventBatch();
      await _db!.delete(_decodedEventsTable);
    }
  }

  Future<void> clearAllLocalStorage() async {
    await clearSpoolBatches();
    await clearDecodedEvents();
    await clearSessionCheckpoint();

    if (readableCopyEnabled) {
      await _readableCopyWriter.clearAllFiles();
    }
  }

  Future<void> setReadableCopyMaxFileBytes(int maxFileBytes) async {
    await initialize();
    if (!readableCopyEnabled) {
      return;
    }

    final bounded = maxFileBytes.clamp(128 * 1024, 64 * 1024 * 1024);
    _readableCopyWriter.setMaxFileBytes(bounded);
  }

  Future<ReadableLocalCopyPreview> readReadableCopyPreview({
    int maxFiles = 6,
    int maxLinesPerFile = 8,
    int maxLineLength = 220,
  }) async {
    await initialize();
    if (!readableCopyEnabled) {
      return ReadableLocalCopyPreview.empty;
    }

    final safeMaxFiles = maxFiles < 1 ? 1 : maxFiles;
    final safeMaxLinesPerFile = maxLinesPerFile < 1 ? 1 : maxLinesPerFile;
    final safeMaxLineLength = maxLineLength < 40 ? 40 : maxLineLength;

    return _readableCopyWriter.readPreview(
      maxFiles: safeMaxFiles,
      maxLinesPerFile: safeMaxLinesPerFile,
      maxLineLength: safeMaxLineLength,
    );
  }

  Future<String?> exportReadableCopy({String? exportRootDirectoryPath}) async {
    await initialize();
    if (!readableCopyEnabled) {
      return null;
    }

    return _readableCopyWriter.exportSnapshot(
      exportRootDirectoryPath: exportRootDirectoryPath,
    );
  }

  Future<void> close() async {
    _csvFlushTimer?.cancel();
    _csvFlushTimer = null;
    _decodedEventFlushTimer?.cancel();
    _decodedEventFlushTimer = null;
    await _flushDecodedEventBatch();
    final db = _db;
    _db = null;
    if (db != null) {
      await db.close();
    }
    await _readableCopyWriter.close();
    spoolHealth.dispose();
    _initialized = false;
    _usingMemoryFallback = forceInMemory;
  }

  Future<void> _flushDecodedEventBatch() async {
    if (_flushingDecodedBatch) {
      var waitTicks = 0;
      while (_flushingDecodedBatch && waitTicks < 100) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        waitTicks += 1;
      }
      if (_decodedEventBatch.isEmpty) {
        return;
      }
    }
    final db = _db;
    if (db == null || _decodedEventBatch.isEmpty) {
      return;
    }

    _flushingDecodedBatch = true;
    try {
      final rows = List<Map<String, Object?>>.from(_decodedEventBatch);
      _decodedEventBatch.clear();
      final batch = db.batch();
      for (final row in rows) {
        batch.insert(
          _decodedEventsTable,
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    } finally {
      _flushingDecodedBatch = false;
    }
  }

  Future<void> _trimMemoryPendingToCap() async {
    final pending = _memoryRecords.where((record) => record.isPending).toList();
    if (pending.length <= maxPendingBatches) {
      return;
    }

    pending.sort((a, b) => a.enqueuedAtUtc.compareTo(b.enqueuedAtUtc));
    final overflow = pending.length - maxPendingBatches;
    for (int i = 0; i < overflow; i++) {
      final record = pending[i];
      await recordAttempt(
        batchId: record.id,
        outcome: 'dropped_overflow',
        incrementAttemptCounter: false,
      );
      await markPublished(batchId: record.id);
      if (record.sessionId != null &&
          record.seqInSessionStart != null &&
          record.seqInSessionEnd != null) {
        await markDecodedEventsPublishedRange(
          sessionId: record.sessionId!,
          seqInSessionStart: record.seqInSessionStart!,
          seqInSessionEnd: record.seqInSessionEnd!,
        );
      }
    }
  }

  Future<void> _trimDbPendingToCap() async {
    if (_db == null) {
      return;
    }

    final rows = await _db!.rawQuery(
      'SELECT id, session_id, seq_in_session_start, seq_in_session_end FROM $_batchesTable WHERE published_at_utc IS NULL ORDER BY enqueued_at_utc ASC',
    );

    if (rows.length <= maxPendingBatches) {
      return;
    }

    final overflow = rows.length - maxPendingBatches;
    for (int i = 0; i < overflow; i++) {
      final batchId = (rows[i]['id'] as num).toInt();
      final sessionId = rows[i]['session_id'] as String?;
      final seqStart = (rows[i]['seq_in_session_start'] as num?)?.toInt();
      final seqEnd = (rows[i]['seq_in_session_end'] as num?)?.toInt();
      await recordAttempt(
        batchId: batchId,
        outcome: 'dropped_overflow',
        incrementAttemptCounter: false,
      );
      await markPublished(batchId: batchId);
      if (sessionId != null && seqStart != null && seqEnd != null) {
        await markDecodedEventsPublishedRange(
          sessionId: sessionId,
          seqInSessionStart: seqStart,
          seqInSessionEnd: seqEnd,
        );
      }
    }
  }

  Future<void> _appendSessionCsvEvent({
    required String sessionId,
    required int seqInSession,
    required String eventJson,
  }) async {
    if (!readableCopyEnabled) {
      return;
    }

    try {
      final decoded = jsonDecode(eventJson);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final row = <String, Object?>{
        'ts_wall_utc': decoded['ts_wall_utc'],
        'ts_session_ms': decoded['ts_session_ms'],
        'session_id': decoded['session_id'] ?? sessionId,
        'lap_number': decoded['lap_number'],
        'session_state': decoded['session_state'],
        'lap_phase': decoded['lap_phase'],
        'metric_key': decoded['metric_key'],
        'metric_value': decoded['metric_value'],
        'unit': decoded['unit'],
        'source': decoded['source'],
        'can_id': decoded['can_id'],
        'seq_in_session': decoded['seq_in_session'] ?? seqInSession,
        'quality_flag': decoded['quality_flag'],
      };

      await _readableCopyWriter.appendSessionCsvRow(
        sessionId: sessionId,
        row: row,
      );
    } catch (e) {
      debugPrint('Session CSV append failed: $e');
    }
  }
}
