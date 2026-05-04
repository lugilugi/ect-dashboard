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

class SpoolRawFrameRecord {
  final int id;
  final String sessionId;
  final DateTime tsWallUtc;
  final int tsSessionMs;
  final int canId;
  final String payloadHex;
  final String source;

  const SpoolRawFrameRecord({
    required this.id,
    required this.sessionId,
    required this.tsWallUtc,
    required this.tsSessionMs,
    required this.canId,
    required this.payloadHex,
    required this.source,
  });
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

class LocalSpoolService {
  static const String _dbName = 'edge_spool.db';
  static const String _batchesTable = 'publish_batches';
  static const String _attemptsTable = 'publish_attempts';
  static const String _decodedEventsTable = 'decoded_events';
  static const String _rawFramesTable = 'raw_frames';
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
  int _nextMemoryRawFrameId = 1;
  final List<SpoolBatchRecord> _memoryRecords = <SpoolBatchRecord>[];
  final List<SpoolDecodedEventRecord> _memoryDecodedEvents =
      <SpoolDecodedEventRecord>[];
  final List<SpoolRawFrameRecord> _memoryRawFrames = <SpoolRawFrameRecord>[];
  String? _memorySessionCheckpointJson;

  LocalSpoolService({
    this.maxPendingBatches = 2000,
    this.forceInMemory = false,
    this.readableCopyEnabled = true,
    this.readableCopyDirectoryPath,
    this.readableCopyMaxFileBytes = 4 * 1024 * 1024,
    ReadableLocalCopyWriter? readableCopyWriter,
  }) : _readableCopyWriter =
           readableCopyWriter ??
           ReadableLocalCopyWriter(maxFileBytes: readableCopyMaxFileBytes);

  bool get isUsingMemoryFallback => _usingMemoryFallback;
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
          version: 2,
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
            CREATE TABLE $_attemptsTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              batch_id INTEGER NOT NULL,
              attempted_at_utc TEXT NOT NULL,
              outcome TEXT NOT NULL,
              error_reason TEXT,
              FOREIGN KEY(batch_id) REFERENCES $_batchesTable(id)
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
            CREATE TABLE $_rawFramesTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_id TEXT NOT NULL,
              ts_wall_utc TEXT NOT NULL,
              ts_session_ms INTEGER NOT NULL,
              can_id INTEGER NOT NULL,
              payload_hex TEXT NOT NULL,
              source TEXT NOT NULL
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
              'CREATE INDEX idx_attempts_batch ON $_attemptsTable(batch_id, attempted_at_utc)',
            );
            await db.execute(
              'CREATE INDEX idx_decoded_pending ON $_decodedEventsTable(published_at_utc, enqueued_at_utc)',
            );
            await db.execute(
              'CREATE INDEX idx_decoded_session_seq ON $_decodedEventsTable(session_id, seq_in_session)',
            );
            await db.execute(
              'CREATE INDEX idx_raw_frames_time ON $_rawFramesTable(ts_wall_utc)',
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
      await _appendReadableCopyRecord(
        stream: 'publish_batches',
        record: <String, Object?>{
          'entry': 'enqueue_batch',
          'spool_batch_id': record.id,
          'topic': topic,
          'session_id': sessionId,
          'seq_in_session_start': seqInSessionStart,
          'seq_in_session_end': seqInSessionEnd,
          'payload_preview': _payloadPreview(payloadJson),
          'enqueued_at_utc': enqueued.toIso8601String(),
          'backend': 'memory',
        },
      );
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
    await _appendReadableCopyRecord(
      stream: 'publish_batches',
      record: <String, Object?>{
        'entry': 'enqueue_batch',
        'spool_batch_id': id,
        'topic': topic,
        'session_id': sessionId,
        'seq_in_session_start': seqInSessionStart,
        'seq_in_session_end': seqInSessionEnd,
        'payload_preview': _payloadPreview(payloadJson),
        'enqueued_at_utc': enqueued.toIso8601String(),
        'backend': 'sqlite',
      },
    );
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
      await _appendReadableCopyRecord(
        stream: 'decoded_events',
        record: <String, Object?>{
          'entry': 'enqueue_decoded_event',
          'session_id': sessionId,
          'seq_in_session': seqInSession,
          'event_preview': _payloadPreview(eventJson),
          'enqueued_at_utc': enqueued.toIso8601String(),
          'backend': 'memory',
        },
      );
      await _appendSessionCsvEvent(
        sessionId: sessionId,
        seqInSession: seqInSession,
        eventJson: eventJson,
      );
      return;
    }

    await _db!.insert(_decodedEventsTable, <String, Object?>{
      'session_id': sessionId,
      'seq_in_session': seqInSession,
      'event_json': eventJson,
      'enqueued_at_utc': enqueued.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _appendReadableCopyRecord(
      stream: 'decoded_events',
      record: <String, Object?>{
        'entry': 'enqueue_decoded_event',
        'session_id': sessionId,
        'seq_in_session': seqInSession,
        'event_preview': _payloadPreview(eventJson),
        'enqueued_at_utc': enqueued.toIso8601String(),
        'backend': 'sqlite',
      },
    );
    await _appendSessionCsvEvent(
      sessionId: sessionId,
      seqInSession: seqInSession,
      eventJson: eventJson,
    );
  }

  Future<int> pendingDecodedEventCount() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      return _memoryDecodedEvents.where((record) => record.isPending).length;
    }

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
      await _appendReadableCopyRecord(
        stream: 'decoded_events',
        record: <String, Object?>{
          'entry': 'mark_decoded_events_published_range',
          'session_id': sessionId,
          'seq_in_session_start': seqInSessionStart,
          'seq_in_session_end': seqInSessionEnd,
          'published_at_utc': published.toIso8601String(),
          'backend': 'memory',
        },
      );
      return;
    }

    await _db!.rawUpdate(
      'UPDATE $_decodedEventsTable SET published_at_utc = ? WHERE session_id = ? AND seq_in_session BETWEEN ? AND ? AND published_at_utc IS NULL',
      <Object?>[
        published.toIso8601String(),
        sessionId,
        seqInSessionStart,
        seqInSessionEnd,
      ],
    );
    await _appendReadableCopyRecord(
      stream: 'decoded_events',
      record: <String, Object?>{
        'entry': 'mark_decoded_events_published_range',
        'session_id': sessionId,
        'seq_in_session_start': seqInSessionStart,
        'seq_in_session_end': seqInSessionEnd,
        'published_at_utc': published.toIso8601String(),
        'backend': _usingMemoryFallback ? 'memory' : 'sqlite',
      },
    );
  }

  Future<void> enqueueRawFrame({
    required String sessionId,
    required int tsSessionMs,
    required int canId,
    required String payloadHex,
    required String source,
    DateTime? tsWallUtc,
  }) async {
    await initialize();
    final tsWall = (tsWallUtc ?? DateTime.now().toUtc()).toUtc();

    if (_usingMemoryFallback || _db == null) {
      _memoryRawFrames.add(
        SpoolRawFrameRecord(
          id: _nextMemoryRawFrameId++,
          sessionId: sessionId,
          tsWallUtc: tsWall,
          tsSessionMs: tsSessionMs,
          canId: canId,
          payloadHex: payloadHex,
          source: source,
        ),
      );
      await _appendReadableCopyRecord(
        stream: 'raw_frames',
        record: <String, Object?>{
          'entry': 'enqueue_raw_frame',
          'session_id': sessionId,
          'ts_wall_utc': tsWall.toIso8601String(),
          'ts_session_ms': tsSessionMs,
          'can_id': canId,
          'payload_hex': payloadHex,
          'source': source,
          'backend': 'memory',
        },
      );
      return;
    }

    await _db!.insert(_rawFramesTable, <String, Object?>{
      'session_id': sessionId,
      'ts_wall_utc': tsWall.toIso8601String(),
      'ts_session_ms': tsSessionMs,
      'can_id': canId,
      'payload_hex': payloadHex,
      'source': source,
    });
    await _appendReadableCopyRecord(
      stream: 'raw_frames',
      record: <String, Object?>{
        'entry': 'enqueue_raw_frame',
        'session_id': sessionId,
        'ts_wall_utc': tsWall.toIso8601String(),
        'ts_session_ms': tsSessionMs,
        'can_id': canId,
        'payload_hex': payloadHex,
        'source': source,
        'backend': 'sqlite',
      },
    );
  }

  Future<int> rawFrameCount() async {
    await initialize();

    if (_usingMemoryFallback || _db == null) {
      return _memoryRawFrames.length;
    }

    final rows = await _db!.rawQuery(
      'SELECT COUNT(*) AS count FROM $_rawFramesTable',
    );
    return (rows.first['count'] as num?)?.toInt() ?? 0;
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
      await _appendReadableCopyRecord(
        stream: 'publish_attempts',
        record: <String, Object?>{
          'entry': 'record_attempt',
          'spool_batch_id': batchId,
          'outcome': outcome,
          'error_reason': errorReason,
          'attempted_at_utc': attempted.toIso8601String(),
          'increment_attempt_counter': incrementAttemptCounter,
          'backend': 'memory',
        },
      );
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

    await _db!.insert(_attemptsTable, <String, Object?>{
      'batch_id': batchId,
      'attempted_at_utc': attempted.toIso8601String(),
      'outcome': outcome,
      'error_reason': errorReason,
    });
    await _appendReadableCopyRecord(
      stream: 'publish_attempts',
      record: <String, Object?>{
        'entry': 'record_attempt',
        'spool_batch_id': batchId,
        'outcome': outcome,
        'error_reason': errorReason,
        'attempted_at_utc': attempted.toIso8601String(),
        'increment_attempt_counter': incrementAttemptCounter,
        'backend': 'sqlite',
      },
    );
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
      await _appendReadableCopyRecord(
        stream: 'publish_batches',
        record: <String, Object?>{
          'entry': 'mark_batch_published',
          'spool_batch_id': batchId,
          'published_at_utc': published.toIso8601String(),
          'backend': 'memory',
        },
      );
      return;
    }

    await _db!.update(
      _batchesTable,
      <String, Object?>{'published_at_utc': published.toIso8601String()},
      where: 'id = ?',
      whereArgs: <Object?>[batchId],
    );
    await _appendReadableCopyRecord(
      stream: 'publish_batches',
      record: <String, Object?>{
        'entry': 'mark_batch_published',
        'spool_batch_id': batchId,
        'published_at_utc': published.toIso8601String(),
        'backend': 'sqlite',
      },
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
      await _appendReadableCopyRecord(
        stream: 'session_checkpoints',
        record: <String, Object?>{
          'entry': 'save_session_checkpoint',
          'checkpoint_preview': _payloadPreview(checkpointJson),
          'updated_at_utc': updatedAt.toIso8601String(),
          'backend': 'memory',
        },
      );
      return;
    }

    await _db!.insert(_checkpointsTable, <String, Object?>{
      'id': 1,
      'checkpoint_json': checkpointJson,
      'updated_at_utc': updatedAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _appendReadableCopyRecord(
      stream: 'session_checkpoints',
      record: <String, Object?>{
        'entry': 'save_session_checkpoint',
        'checkpoint_preview': _payloadPreview(checkpointJson),
        'updated_at_utc': updatedAt.toIso8601String(),
        'backend': 'sqlite',
      },
    );
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
      await _appendReadableCopyRecord(
        stream: 'session_checkpoints',
        record: <String, Object?>{
          'entry': 'clear_session_checkpoint',
          'backend': 'memory',
        },
      );
      return;
    }

    await _db!.delete(_checkpointsTable, where: 'id = 1');
    await _appendReadableCopyRecord(
      stream: 'session_checkpoints',
      record: <String, Object?>{
        'entry': 'clear_session_checkpoint',
        'backend': 'sqlite',
      },
    );
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
    await _db!.delete(
      _attemptsTable,
      where: 'batch_id NOT IN (SELECT id FROM $_batchesTable)',
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

    await _db!.delete(
      _decodedEventsTable,
      where: 'published_at_utc IS NOT NULL AND published_at_utc < ?',
      whereArgs: <Object?>[cutoff.toIso8601String()],
    );
  }

  Future<void> pruneRawFramesOlderThan(Duration maxAge) async {
    await initialize();
    final cutoff = DateTime.now().toUtc().subtract(maxAge);

    if (_usingMemoryFallback || _db == null) {
      _memoryRawFrames.removeWhere(
        (record) => record.tsWallUtc.isBefore(cutoff),
      );
      return;
    }

    await _db!.delete(
      _rawFramesTable,
      where: 'ts_wall_utc < ?',
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

  Future<void> _appendReadableCopyRecord({
    required String stream,
    required Map<String, Object?> record,
  }) async {
    if (!readableCopyEnabled) {
      return;
    }

    // CSV-only storage mode intentionally disables JSONL mirror streams.
    if (stream.isEmpty && record.isEmpty) {
      return;
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

      final csvFilePath = await _readableCopyWriter.appendSessionCsvRow(
        sessionId: sessionId,
        row: row,
      );

      if (csvFilePath == null || csvFilePath.isEmpty) {
        return;
      }

      await _appendReadableCopyRecord(
        stream: 'session_csv',
        record: <String, Object?>{
          'entry': 'append_session_csv',
          'session_id': sessionId,
          'seq_in_session': row['seq_in_session'],
          'metric_key': row['metric_key'],
          'csv_file': csvFilePath,
          'backend': _usingMemoryFallback ? 'memory' : 'sqlite',
        },
      );
    } catch (e) {
      debugPrint('Session CSV append failed: $e');
    }
  }

  String _payloadPreview(String payload, {int maxChars = 240}) {
    if (payload.length <= maxChars) {
      return payload;
    }
    return '${payload.substring(0, maxChars)}...';
  }
}
