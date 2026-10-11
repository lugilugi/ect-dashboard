import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/services/persistence/spool_health_store.dart';
import 'package:telemetry_dashboard/services/persistence/readable_local_copy_writer.dart';

/// Outcome of one [TelemetryJournal.appendRecords] transaction.
///
/// Policy failures (quota, identity conflict) are reported here and the rest
/// of the batch is still committed. Only real storage failures (SQLite/I/O)
/// throw, in which case nothing from the batch was committed.
class AppendResult {
  /// Rows newly inserted into the journal.
  final int stored;

  /// Records whose identity already existed with identical content
  /// (idempotent retry); nothing was written for them.
  final int duplicates;

  /// Metric records rejected because the pending byte budget was full. Their
  /// identities are consumed (watermarks advanced) and they are counted once
  /// in one `recording_losses` row for this append.
  final List<String> quotaRejectedKeys;

  /// Records whose identity already existed with different content. They are
  /// moved to `journal_failed` and never delivered.
  final List<String> conflictKeys;

  /// Highest journal id inserted by this append, or null when none.
  final int? lastInsertedId;

  const AppendResult({
    this.stored = 0,
    this.duplicates = 0,
    this.quotaRejectedKeys = const [],
    this.conflictKeys = const [],
    this.lastInsertedId,
  });

  int get quotaRejected => quotaRejectedKeys.length;
  List<String> get conflicts => conflictKeys;
}

class _Failure {
  final TelemetryRecord record;
  final String reason;
  const _Failure(this.record, this.reason);
}

/// Immutable durable records. There is no automatic RAM fallback.
///
/// The journal is the single owner of pending-backlog accounting: count,
/// bytes and oldest pending record are loaded once at open and adjusted
/// after each committed insert/ack/drop, so the cost of a save does not grow
/// with the backlog.
class TelemetryJournal {
  static const schemaVersion = 5;
  static const quotaLossReason = 'pending byte budget exceeded';

  final String? databasePath;
  final DatabaseFactory? factory;
  final int maxPendingBytes;
  final bool readableCopyEnabled;
  final String? readableCopyDirectoryPath;

  /// Minimum spacing between commit-triggered CSV exports.
  final Duration exportInterval;
  final ReadableLocalCopyWriter _writer;
  final SpoolHealthStore spoolHealth = SpoolHealthStore();
  final StreamController<int> _commits = StreamController<int>.broadcast();
  Database? _db;
  Future<void>? _initializing;
  Future<void>? _exporting;
  Future<void> _mutationTail = Future<void>.value();
  Timer? _exportTimer;
  final Stopwatch _sinceExport = Stopwatch();
  bool _closed = false;

  int _pendingCount = 0;
  int _pendingBytes = 0;
  int? _oldestPendingId;
  DateTime? _oldestPendingAtUtc;
  int _failedCount = 0;
  int _lastCommittedId = 0;

  /// recording_losses row extended while a quota loss is sustained.
  int? _openLossRowId;
  String? _openLossSession;

  TelemetryJournal({
    this.databasePath,
    this.factory,
    this.maxPendingBytes = 256 * 1024 * 1024,
    this.readableCopyEnabled = true,
    this.readableCopyDirectoryPath,
    this.exportInterval = const Duration(seconds: 2),
    int readableCopyMaxFileBytes = 4 * 1024 * 1024,
    ReadableLocalCopyWriter? writer,
  }) : _writer =
           writer ??
           ReadableLocalCopyWriter(maxFileBytes: readableCopyMaxFileBytes);

  String? get readableCopyPath => _writer.directoryPath;
  String? get sessionCsvPath => _writer.sessionCsvDirectoryPath;

  /// Emits the highest committed journal id after each append that inserted
  /// records. Consumers (the MQTT sender) read committed rows from SQLite.
  Stream<int> get commits => _commits.stream;
  int get lastCommittedId => _lastCommittedId;
  int get pendingCount => _pendingCount;
  int get pendingBytes => _pendingBytes;
  int get failedRecordCount => _failedCount;

  Future<void> initialize() {
    if (_closed) return Future.error(StateError('Journal is closed'));
    if (_db != null) return Future.value();
    return _initializing ??= _open().whenComplete(() => _initializing = null);
  }

  Future<void> _open() async {
    try {
      if (kIsWeb) {
        throw UnsupportedError('Durable telemetry needs native SQLite');
      }
      final desktop =
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS;
      if (desktop && factory == null) sqfliteFfiInit();
      final selected =
          factory ?? (desktop ? databaseFactoryFfi : databaseFactory);
      final path =
          databasePath ??
          p.join(await selected.getDatabasesPath(), 'edge_spool.db');
      final db = await selected.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onConfigure: (db) async {
            // This pragma returns a row; Android execSQL rejects query results.
            await db.rawQuery('PRAGMA journal_mode=WAL');
            await db.execute('PRAGMA synchronous=FULL');
          },
          onCreate: (db, version) => _create(db),
          onUpgrade: _upgrade,
        ),
      );
      await _recount(db);
      _db = db;
      if (readableCopyEnabled) {
        try {
          await _initializeWriter(path);
        } catch (error) {
          spoolHealth.updateRecordingErrors(export: error.toString());
        }
      }
      _publishHealth();
    } catch (error) {
      spoolHealth.updateRecordingErrors(storage: error.toString());
      rethrow;
    }
  }

  Future<void> _initializeWriter(String path) => _writer.initialize(
    baseDirectoryPath: p.dirname(path),
    overrideDirectoryPath:
        readableCopyDirectoryPath ?? p.join(p.dirname(path), 'session_csv_v2'),
  );

  /// Explicit per-version migrations. Versions before 4 belong to the
  /// intentionally reset legacy format (ADR 0001); 4 → 5 preserves every
  /// journal row, watermark, checkpoint and export cursor.
  static Future<void> _upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 4) {
      for (final table in [
        'publish_batches',
        'decoded_events',
        'session_checkpoints',
        'publish_attempts',
        'raw_frames',
      ]) {
        await db.execute('DROP TABLE IF EXISTS $table');
      }
      await _create(db);
      return;
    }
    if (oldVersion < 5) await _migrateV4ToV5(db);
  }

  static Future<void> _migrateV4ToV5(DatabaseExecutor db) async {
    // One row now summarizes a whole rejected append instead of one per record.
    await db.execute(
      'ALTER TABLE recording_losses ADD COLUMN record_count INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE recording_losses ADD COLUMN last_record_key TEXT',
    );
    await _createFailedTable(db);
  }

  static Future<void> _create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS journal (
      id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL, session_uid TEXT NOT NULL, identity_number INTEGER NOT NULL,
      payload_json TEXT NOT NULL, payload_bytes INTEGER NOT NULL,
      enqueued_at_utc TEXT NOT NULL, delivery_state TEXT NOT NULL DEFAULT 'pending',
      attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, broker_acked_at_utc TEXT
    )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS journal_pending ON journal(delivery_state,id)',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS session_watermarks (
      session_uid TEXT PRIMARY KEY, sequence INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 0
    )''');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS control_checkpoint (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS export_state (id INTEGER PRIMARY KEY CHECK(id=1), last_id INTEGER NOT NULL)',
    );
    await db.rawInsert(
      'INSERT OR IGNORE INTO export_state(id,last_id) VALUES(1,0)',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS recording_losses (
      id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL,
      recorded_at_utc TEXT NOT NULL, reason TEXT NOT NULL,
      record_count INTEGER NOT NULL DEFAULT 1, last_record_key TEXT
    )''');
    await _createFailedTable(db);
  }

  static Future<void> _createFailedTable(DatabaseExecutor db) =>
      db.execute('''CREATE TABLE IF NOT EXISTS journal_failed (
      id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL,
      payload_json TEXT NOT NULL, reason TEXT NOT NULL, recorded_at_utc TEXT NOT NULL
    )''');

  /// Serializes mutations so each SQLite commit and its in-memory accounting
  /// update are applied together, in commit order.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _mutationTail.then((_) => action());
    // The chain only orders work; the caller receives [result] and its error.
    _mutationTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Slow full recount; only used at open and after clearing storage.
  Future<void> _recount(DatabaseExecutor db) async {
    final row = (await db.rawQuery(
      "SELECT count(*) AS count,COALESCE(sum(payload_bytes),0) AS bytes "
      "FROM journal WHERE delivery_state='pending'",
    )).single;
    _pendingCount = row['count'] as int;
    _pendingBytes = row['bytes'] as int;
    _applyOldest(await _readOldest(db));
    _failedCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT count(*) FROM journal_failed'),
    )!;
    _lastCommittedId = math.max(
      _lastCommittedId,
      Sqflite.firstIntValue(
            await db.rawQuery('SELECT COALESCE(max(id),0) FROM journal'),
          ) ??
          0,
    );
  }

  /// Lowest pending id via the journal_pending index. Callers inside a
  /// transaction apply the result only after it commits.
  static Future<(int?, DateTime?)> _readOldest(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT id,enqueued_at_utc FROM journal WHERE delivery_state='pending' "
      'ORDER BY id LIMIT 1',
    );
    if (rows.isEmpty) return (null, null);
    return (
      rows.single['id'] as int,
      DateTime.parse(rows.single['enqueued_at_utc'] as String),
    );
  }

  void _applyOldest((int?, DateTime?) oldest) {
    _oldestPendingId = oldest.$1;
    _oldestPendingAtUtc = oldest.$2;
  }

  void _publishHealth() {
    spoolHealth.updateBacklog(
      count: _pendingCount,
      oldestEnqueuedAtUtc: _oldestPendingAtUtc,
    );
    spoolHealth.updatePendingCapacity(
      pendingBytes: _pendingBytes,
      byteCapacity: maxPendingBytes,
    );
    spoolHealth.updateFailedRecordCount(_failedCount);
  }

  /// Commits [records] (and optionally the control checkpoint) atomically.
  ///
  /// Policies: within-budget records are stored; capture metrics beyond the
  /// pending byte budget are rejected for quota (identity consumed, counted
  /// once, a sustained loss extends one `recording_losses` row); control
  /// records ([TelemetryRecord.control]: session metadata, lap, recovery and
  /// loss events) are always stored because they are tiny and SQL session/lap
  /// structure depends on them; a record whose identity exists with different
  /// content goes to `journal_failed`. Duplicates add no pending bytes and do
  /// not cause quota rejection. SQLite/I/O errors propagate and roll back the
  /// batch.
  Future<AppendResult> appendRecords(
    List<TelemetryRecord> records, {
    String? checkpointJson,
    bool replaceCheckpoint = true,
  }) async {
    await initialize();
    try {
      final result = await _serialized(
        () => _append(records, checkpointJson, replaceCheckpoint),
      );
      if (result.quotaRejected > 0) {
        spoolHealth.recordQuotaRejection(
          result.quotaRejected,
          message:
              'Recording quota exceeded: $quotaLossReason '
              '(${result.quotaRejected} records rejected)',
        );
      } else {
        spoolHealth.clearStorageError();
      }
      _publishHealth();
      final last = result.lastInsertedId;
      if (last != null) {
        if (!_commits.isClosed) _commits.add(last);
        _scheduleExport();
      }
      return result;
    } catch (error) {
      spoolHealth.updateRecordingErrors(
        storage: error.toString(),
        export: spoolHealth.exportError,
      );
      rethrow;
    }
  }

  Future<AppendResult> _append(
    List<TelemetryRecord> records,
    String? checkpointJson,
    bool replaceCheckpoint,
  ) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final unique = <String, TelemetryRecord>{};
    final failures = <_Failure>[];
    for (final record in records) {
      final prior = unique.putIfAbsent(record.key, () => record);
      if (!identical(prior, record) &&
          prior.payloadJson != record.payloadJson) {
        failures.add(
          _Failure(record, 'conflicting identity within one append'),
        );
      }
    }
    // Watermarks advance for every identity seen, stored or not, so a
    // sequence/revision is never reused after rejection or conflict.
    final sequences = <String, int>{};
    final revisions = <String, int>{};
    final sizeOf = <String, int>{};
    var totalBytes = 0;
    for (final record in unique.values) {
      final marks = record.kind == TelemetryRecordKind.metric
          ? sequences
          : revisions;
      marks[record.sessionId] = math.max(
        marks[record.sessionId] ?? 0,
        record.identityNumber,
      );
      final bytes = utf8ByteLength(record.payloadJson);
      sizeOf[record.key] = bytes;
      totalBytes += bytes;
    }

    var insertedCount = 0;
    var insertedBytes = 0;
    var capturedInserted = 0;
    var duplicates = 0;
    int? minInserted;
    int? maxInserted;
    var rejected = <TelemetryRecord>[];
    int? lossRowId;
    await _db!.transaction((tx) async {
      final skipped = <TelemetryRecord>[];
      Future<void> insertAll(List<TelemetryRecord> batch) async {
        if (batch.isEmpty) return;
        final insert = tx.batch();
        for (final record in batch) {
          insert.rawInsert(
            'INSERT OR IGNORE INTO journal(record_key,kind,session_uid,'
            'identity_number,payload_json,payload_bytes,enqueued_at_utc) '
            'VALUES(?,?,?,?,?,?,?)',
            [
              record.key,
              record.kind.name,
              record.sessionId,
              record.identityNumber,
              record.payloadJson,
              sizeOf[record.key],
              nowIso,
            ],
          );
        }
        final ids = await insert.commit();
        for (var i = 0; i < batch.length; i++) {
          final id = ids[i];
          // FFI returns null and Android returns -1 when the insert was ignored.
          if (id is int && id > 0) {
            insertedCount++;
            insertedBytes += sizeOf[batch[i].key]!;
            if (!batch[i].control) capturedInserted++;
            minInserted = math.min(minInserted ?? id, id);
            maxInserted = math.max(maxInserted ?? id, id);
          } else {
            skipped.add(batch[i]);
          }
        }
      }

      if (_pendingBytes + totalBytes <= maxPendingBytes) {
        // Common case: everything fits; keep capture order.
        await insertAll(unique.values.toList());
      } else {
        // Control records (metadata, lap, recovery, loss) are always stored.
        // Capture metrics are admitted in order against the bytes actually
        // pending; an ignored duplicate adds no bytes, so its room is
        // offered to the next records. The first record that does not fit
        // ends admission, so the loss is one contiguous range.
        final capture = <TelemetryRecord>[];
        final control = <TelemetryRecord>[];
        for (final record in unique.values) {
          (record.control ? control : capture).add(record);
        }
        await insertAll(control);
        var next = 0;
        while (next < capture.length) {
          var room = maxPendingBytes - (_pendingBytes + insertedBytes);
          final round = <TelemetryRecord>[];
          while (next < capture.length && sizeOf[capture[next].key]! <= room) {
            room -= sizeOf[capture[next].key]!;
            round.add(capture[next++]);
          }
          if (round.isEmpty) break;
          final skippedBefore = skipped.length;
          await insertAll(round);
          if (skipped.length == skippedBefore) break;
        }
        rejected = capture.sublist(next);
      }

      void classifyStored(TelemetryRecord record, String stored) {
        if (stored == record.payloadJson) {
          duplicates++;
        } else {
          failures.add(
            _Failure(record, 'conflicting identity: stored payload differs'),
          );
        }
      }

      if (skipped.isNotEmpty) {
        // Only ignored inserts (retries/conflicts) read the stored row.
        final existing = await _storedPayloads(tx, skipped);
        for (final record in skipped) {
          final stored = existing[record.key];
          if (stored == null) {
            throw StateError(
              'Journal insert skipped without a stored row: ${record.key}',
            );
          }
          classifyStored(record, stored);
        }
      }
      if (rejected.isNotEmpty) {
        // An over-budget identity that is already stored is a retry or a
        // conflict, not a recording loss.
        final existing = await _storedPayloads(tx, rejected);
        rejected.removeWhere((record) {
          final stored = existing[record.key];
          if (stored == null) return false;
          classifyStored(record, stored);
          return true;
        });
      }
      if (rejected.isNotEmpty) {
        // A sustained loss (no capture stored since the last rejection, same
        // session) extends one recording_losses row instead of adding one
        // per commit.
        final open = _openLossRowId;
        var extended = 0;
        if (open != null && _openLossSession == rejected.first.sessionId) {
          extended = await tx.rawUpdate(
            'UPDATE recording_losses SET record_count=record_count+?,'
            'last_record_key=? WHERE id=?',
            [rejected.length, rejected.last.key, open],
          );
        }
        lossRowId = extended > 0
            ? open
            : await tx.insert('recording_losses', {
                'record_key': rejected.first.key,
                'last_record_key': rejected.last.key,
                'record_count': rejected.length,
                'recorded_at_utc': nowIso,
                'reason': quotaLossReason,
              });
      }
      final tail = tx.batch();
      for (final sessionId in {...sequences.keys, ...revisions.keys}) {
        tail.rawInsert(
          '''INSERT INTO session_watermarks(session_uid,sequence,revision)
          VALUES(?,?,?) ON CONFLICT(session_uid) DO UPDATE SET
          sequence=max(sequence,excluded.sequence),revision=max(revision,excluded.revision)''',
          [sessionId, sequences[sessionId] ?? 0, revisions[sessionId] ?? 0],
        );
      }
      for (final failure in failures) {
        tail.insert('journal_failed', {
          'record_key': failure.record.key,
          'payload_json': failure.record.payloadJson,
          'reason': failure.reason,
          'recorded_at_utc': nowIso,
        });
      }
      if (replaceCheckpoint) {
        tail.delete('control_checkpoint');
        if (checkpointJson != null) {
          tail.insert('control_checkpoint', {'id': 1, 'json': checkpointJson});
        }
      }
      await tail.commit(noResult: true);
    });
    // Committed: apply accounting.
    _pendingCount += insertedCount;
    _pendingBytes += insertedBytes;
    if (minInserted != null && _oldestPendingId == null) {
      _oldestPendingId = minInserted;
      _oldestPendingAtUtc = DateTime.parse(nowIso);
    }
    _failedCount += failures.length;
    if (maxInserted != null) {
      _lastCommittedId = math.max(_lastCommittedId, maxInserted!);
    }
    if (rejected.isNotEmpty) {
      _openLossRowId = lossRowId;
      _openLossSession = rejected.first.sessionId;
    } else if (capturedInserted > 0) {
      _openLossRowId = null;
      _openLossSession = null;
    }
    return AppendResult(
      stored: insertedCount,
      duplicates: duplicates,
      quotaRejectedKeys: [for (final record in rejected) record.key],
      conflictKeys: [for (final failure in failures) failure.record.key],
      lastInsertedId: maxInserted,
    );
  }

  /// Stored payload_json by record_key for those of [records] that exist.
  static Future<Map<String, String>> _storedPayloads(
    DatabaseExecutor tx,
    List<TelemetryRecord> records,
  ) async {
    final existing = <String, String>{};
    for (var start = 0; start < records.length; start += 400) {
      final chunk = records.sublist(
        start,
        math.min(start + 400, records.length),
      );
      final rows = await tx.rawQuery(
        'SELECT record_key,payload_json FROM journal WHERE record_key IN '
        '(${List.filled(chunk.length, '?').join(',')})',
        [for (final record in chunk) record.key],
      );
      for (final row in rows) {
        existing[row['record_key'] as String] = row['payload_json'] as String;
      }
    }
    return existing;
  }

  Future<List<PendingJournalRecord>> readPending({int limit = 32}) async {
    await initialize();
    final rows = await _db!.rawQuery(
      'SELECT id,kind,session_uid,identity_number,payload_json,payload_bytes,'
      "enqueued_at_utc,attempt_count FROM journal WHERE delivery_state='pending' "
      'ORDER BY id LIMIT ?',
      [limit],
    );
    return rows
        .map(
          (row) => PendingJournalRecord(
            row['id'] as int,
            TelemetryRecord(
              kind: TelemetryRecordKind.values.byName(row['kind'] as String),
              sessionId: row['session_uid'] as String,
              identityNumber: row['identity_number'] as int,
              payloadJson: row['payload_json'] as String,
            ),
            DateTime.parse(row['enqueued_at_utc'] as String),
            row['attempt_count'] as int,
            payloadBytes: row['payload_bytes'] as int,
          ),
        )
        .toList();
  }

  /// Marks [ids] broker-acknowledged. A PUBACK is a broker handoff, not proof
  /// of SQL durability.
  Future<void> markBrokerAcknowledged(List<int> ids) =>
      recordDeliveryRound(acked: ids);

  /// Applies one sender round in a single transaction: [acked] ids become
  /// broker_acked and [failed] ids stay pending with [error]; both get
  /// attempt_count+1 in the same statement that changes them.
  Future<void> recordDeliveryRound({
    List<int> acked = const [],
    List<int> failed = const [],
    String? error,
  }) async {
    await initialize();
    if (acked.isEmpty && failed.isEmpty) return;
    await _serialized(() async {
      var ackedCount = 0;
      var ackedBytes = 0;
      final oldest = _oldestPendingId;
      final reReadOldest = oldest != null && acked.contains(oldest);
      final nowIso = DateTime.now().toUtc().toIso8601String();
      (int?, DateTime?)? nextOldest;
      await _db!.transaction((tx) async {
        for (final chunk in _chunks(acked)) {
          final ids = chunk.join(',');
          final row = (await tx.rawQuery(
            'SELECT count(*) AS count,COALESCE(sum(payload_bytes),0) AS bytes '
            "FROM journal WHERE id IN ($ids) AND delivery_state='pending'",
          )).single;
          ackedCount += row['count'] as int;
          ackedBytes += row['bytes'] as int;
          await tx.rawUpdate(
            "UPDATE journal SET delivery_state='broker_acked',"
            'broker_acked_at_utc=?,last_error=NULL,attempt_count=attempt_count+1 '
            "WHERE id IN ($ids) AND delivery_state='pending'",
            [nowIso],
          );
        }
        for (final chunk in _chunks(failed)) {
          await tx.rawUpdate(
            'UPDATE journal SET attempt_count=attempt_count+1,last_error=? '
            "WHERE id IN (${chunk.join(',')}) AND delivery_state='pending'",
            [error],
          );
        }
        if (reReadOldest) nextOldest = await _readOldest(tx);
      });
      _pendingCount -= ackedCount;
      _pendingBytes -= ackedBytes;
      if (nextOldest != null) _applyOldest(nextOldest!);
    });
    _publishHealth();
  }

  Future<void> recordAttempt(List<int> ids, {String? error}) async {
    await initialize();
    if (ids.isEmpty) return;
    await _db!.transaction((tx) async {
      for (final chunk in _chunks(ids)) {
        await tx.rawUpdate(
          'UPDATE journal SET attempt_count=attempt_count+1,last_error=? '
          'WHERE id IN (${chunk.join(',')})',
          [error],
        );
      }
    });
  }

  /// Integer ids are inlined (no bound-variable limit); chunks bound SQL size.
  static Iterable<List<int>> _chunks(List<int> ids) sync* {
    for (var start = 0; start < ids.length; start += 500) {
      yield ids.sublist(start, math.min(start + 500, ids.length));
    }
  }

  Future<void> markDropped(int id, String reason) async {
    await initialize();
    await _serialized(() async {
      var count = 0;
      var bytes = 0;
      (int?, DateTime?)? nextOldest;
      await _db!.transaction((tx) async {
        final row = (await tx.rawQuery(
          'SELECT count(*) AS count,COALESCE(sum(payload_bytes),0) AS bytes '
          "FROM journal WHERE id=? AND delivery_state='pending'",
          [id],
        )).single;
        count = row['count'] as int;
        bytes = row['bytes'] as int;
        await tx.update(
          'journal',
          {'delivery_state': 'dropped', 'last_error': reason},
          where: "id=? AND delivery_state='pending'",
          whereArgs: [id],
        );
        if (id == _oldestPendingId) nextOldest = await _readOldest(tx);
      });
      _pendingCount -= count;
      _pendingBytes -= bytes;
      if (nextOldest != null) _applyOldest(nextOldest!);
    });
    spoolHealth.updateRecordingErrors(
      storage: reason,
      export: spoolHealth.exportError,
      rejected: 1,
    );
    _publishHealth();
  }

  Future<int> maxSequence(String sessionId) =>
      _watermark(sessionId, 'sequence');
  Future<int> maxRevision(String sessionId) =>
      _watermark(sessionId, 'revision');
  Future<int> _watermark(String sessionId, String column) async {
    await initialize();
    final rows = await _db!.query(
      'session_watermarks',
      columns: [column],
      where: 'session_uid=?',
      whereArgs: [sessionId],
    );
    return rows.isEmpty ? 0 : rows.single[column] as int;
  }

  Future<String?> readCheckpoint() async {
    await initialize();
    final rows = await _db!.query('control_checkpoint');
    return rows.isEmpty ? null : rows.single['json'] as String;
  }

  /// Publishes the in-memory backlog accounting; performs no SQL.
  Future<void> refreshHealth() async {
    if (_db == null) return;
    _publishHealth();
  }

  /// Coalesces commit-triggered CSV exports to at most one per
  /// [exportInterval]. Explicit [flushExports] calls are not delayed.
  void _scheduleExport() {
    if (_closed || _exportTimer != null) return;
    final elapsed = _sinceExport.isRunning
        ? _sinceExport.elapsed
        : exportInterval;
    final wait = elapsed >= exportInterval
        ? Duration.zero
        : exportInterval - elapsed;
    _exportTimer = Timer(wait, () {
      _exportTimer = null;
      if (_closed || _db == null) return;
      unawaited(
        flushExports().catchError((Object error) {
          // _export already recorded this in spoolHealth.exportError; the
          // cursor is kept and the next trigger retries.
        }),
      );
    });
  }

  Future<void> flushExports() =>
      _exporting ??= _export().whenComplete(() => _exporting = null);
  Future<void> _export() async {
    await initialize();
    _sinceExport
      ..reset()
      ..start();
    try {
      if (readableCopyEnabled && _writer.directoryPath == null) {
        await _initializeWriter(_db!.path);
      }
      var cursor = (await _db!.query('export_state')).single['last_id'] as int;
      while (true) {
        final rows = await _db!.query(
          'journal',
          where: 'id>?',
          whereArgs: [cursor],
          orderBy: 'id',
          limit: 100,
        );
        if (rows.isEmpty) break;
        if (readableCopyEnabled) {
          for (final row in rows) {
            final path = await _writer.appendRecord(
              (jsonDecode(row['payload_json'] as String)
                      as Map<String, dynamic>)
                  .cast<String, Object?>(),
            );
            if (path == null) {
              throw StateError('Local CSV directory unavailable');
            }
          }
          await _writer.flush();
        }
        cursor = rows.last['id'] as int;
        await _db!.update('export_state', {'last_id': cursor}, where: 'id=1');
      }
      if (spoolHealth.exportError != null) {
        spoolHealth.updateRecordingErrors(storage: spoolHealth.storageError);
      }
    } catch (error) {
      spoolHealth.updateRecordingErrors(
        storage: spoolHealth.storageError,
        export: error.toString(),
      );
      rethrow;
    }
  }

  /// Removes broker-acknowledged, exported history and diagnostic rows
  /// (recording_losses, journal_failed) older than [history].
  Future<void> prune({Duration history = const Duration(days: 7)}) async {
    await initialize();
    final cutoff = DateTime.now().toUtc().subtract(history).toIso8601String();
    await _serialized(() async {
      final cursor =
          (await _db!.query('export_state')).single['last_id'] as int;
      var failed = 0;
      await _db!.transaction((tx) async {
        await tx.delete(
          'journal',
          where:
              "delivery_state='broker_acked' AND broker_acked_at_utc<? AND id<=?",
          whereArgs: [cutoff, cursor],
        );
        await tx.delete(
          'recording_losses',
          where: 'recorded_at_utc<?',
          whereArgs: [cutoff],
        );
        await tx.delete(
          'journal_failed',
          where: 'recorded_at_utc<?',
          whereArgs: [cutoff],
        );
        failed = Sqflite.firstIntValue(
          await tx.rawQuery('SELECT count(*) FROM journal_failed'),
        )!;
      });
      _failedCount = failed;
    });
    _publishHealth();
  }

  Future<void> clearAllLocalStorage() async {
    await initialize();
    _exportTimer?.cancel();
    _exportTimer = null;
    await _exporting;
    await _serialized(() async {
      await _db!.transaction((tx) async {
        for (final table in [
          'journal',
          'control_checkpoint',
          'session_watermarks',
          'recording_losses',
          'journal_failed',
        ]) {
          await tx.delete(table);
        }
        await tx.update('export_state', {'last_id': 0});
      });
      _openLossRowId = null;
      _openLossSession = null;
      await _recount(_db!);
    });
    await _writer.clearAllFiles();
    spoolHealth.updateRecordingErrors();
    _publishHealth();
  }

  Future<void> setReadableCopyMaxFileBytes(int bytes) async =>
      _writer.setMaxFileBytes(bytes);
  Future<void> pruneReadableCopyOlderThan(Duration age) async =>
      _writer.pruneOlderThan(age);
  Future<ReadableLocalCopyPreview> readReadableCopyPreview({
    int maxFiles = 6,
    int maxLinesPerFile = 8,
    int maxLineLength = 220,
  }) async {
    await flushExports();
    return _writer.readPreview(
      maxFiles: maxFiles,
      maxLinesPerFile: maxLinesPerFile,
      maxLineLength: maxLineLength,
    );
  }

  Future<String?> exportReadableCopy({String? exportRootDirectoryPath}) async {
    await flushExports();
    return _writer.exportSnapshot(
      exportRootDirectoryPath: exportRootDirectoryPath,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _exportTimer?.cancel();
    _exportTimer = null;
    if (_db != null) {
      await _mutationTail;
      try {
        await flushExports();
      } catch (error) {
        // The cursor is kept for the next restart; keep the failure visible.
        spoolHealth.updateRecordingErrors(
          storage: spoolHealth.storageError,
          export: error.toString(),
        );
      }
      try {
        await _writer.close();
      } catch (error) {
        spoolHealth.updateRecordingErrors(
          storage: spoolHealth.storageError,
          export: error.toString(),
        );
      } finally {
        await _db!.close();
      }
      _db = null;
    }
    _closed = true;
    await _commits.close();
    spoolHealth.dispose();
  }
}
