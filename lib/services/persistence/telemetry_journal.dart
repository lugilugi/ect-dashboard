import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/services/persistence/spool_health_store.dart';
import 'package:telemetry_dashboard/services/persistence/readable_local_copy_writer.dart';

/// Immutable durable records. There is no automatic RAM fallback.
class TelemetryJournal {
  final String? databasePath;
  final DatabaseFactory? factory;
  final int maxPendingBytes;
  final bool readableCopyEnabled;
  final String? readableCopyDirectoryPath;
  final ReadableLocalCopyWriter _writer;
  final SpoolHealthStore spoolHealth = SpoolHealthStore();
  Database? _db;
  Future<void>? _initializing;
  Future<void>? _exporting;
  bool _closed = false;

  TelemetryJournal({
    this.databasePath,
    this.factory,
    this.maxPendingBytes = 256 * 1024 * 1024,
    this.readableCopyEnabled = true,
    this.readableCopyDirectoryPath,
    int readableCopyMaxFileBytes = 4 * 1024 * 1024,
    ReadableLocalCopyWriter? writer,
  }) : _writer =
           writer ??
           ReadableLocalCopyWriter(maxFileBytes: readableCopyMaxFileBytes);

  String? get readableCopyPath => _writer.directoryPath;
  String? get sessionCsvPath => _writer.sessionCsvDirectoryPath;

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
      _db = await selected.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onConfigure: (db) async {
            // This pragma returns a row; Android execSQL rejects query results.
            await db.rawQuery('PRAGMA journal_mode=WAL');
            await db.execute('PRAGMA synchronous=FULL');
          },
          onCreate: (db, version) => _create(db),
          onUpgrade: (db, oldVersion, newVersion) async {
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
          },
        ),
      );
      if (readableCopyEnabled) {
        try {
          await _initializeWriter(path);
        } catch (error) {
          spoolHealth.updateRecordingErrors(export: error.toString());
        }
      }
      await refreshHealth();
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

  Future<void> _create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE journal (
      id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL, session_uid TEXT NOT NULL, identity_number INTEGER NOT NULL,
      payload_json TEXT NOT NULL, payload_bytes INTEGER NOT NULL,
      enqueued_at_utc TEXT NOT NULL, delivery_state TEXT NOT NULL DEFAULT 'pending',
      attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, broker_acked_at_utc TEXT
    )''');
    await db.execute(
      'CREATE INDEX journal_pending ON journal(delivery_state,id)',
    );
    await db.execute('''CREATE TABLE session_watermarks (
      session_uid TEXT PRIMARY KEY, sequence INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 0
    )''');
    await db.execute(
      'CREATE TABLE control_checkpoint (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE export_state (id INTEGER PRIMARY KEY CHECK(id=1), last_id INTEGER NOT NULL)',
    );
    await db.insert('export_state', {'id': 1, 'last_id': 0});
    await db.execute('''CREATE TABLE recording_losses (
      id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL,
      recorded_at_utc TEXT NOT NULL, reason TEXT NOT NULL
    )''');
  }

  Future<void> appendRecords(
    List<TelemetryRecord> records, {
    String? checkpointJson,
    bool replaceCheckpoint = true,
  }) async {
    await initialize();
    try {
      var rejected = false;
      await _db!.transaction((tx) async {
        final additions = <TelemetryRecord>[];
        final withinBatch = <String, String>{};
        for (final record in records) {
          final prior = withinBatch[record.key];
          if (prior != null) {
            if (prior != record.payloadJson) {
              throw StateError('Conflicting journal identity: ${record.key}');
            }
            continue;
          }
          withinBatch[record.key] = record.payloadJson;
          final rows = await tx.query(
            'journal',
            where: 'record_key=?',
            whereArgs: [record.key],
          );
          if (rows.isEmpty) {
            additions.add(record);
          } else if (rows.single['payload_json'] != record.payloadJson) {
            final key = record.key;
            throw StateError('Conflicting journal identity: $key');
          }
        }
        final bytes = Sqflite.firstIntValue(
          await tx.rawQuery(
            "SELECT COALESCE(sum(payload_bytes),0) FROM journal WHERE delivery_state='pending'",
          ),
        )!;
        final added = additions.fold<int>(
          0,
          (n, r) => n + utf8.encode(r.payloadJson).length,
        );
        if (bytes + added > maxPendingBytes) {
          rejected = true;
          for (final record in additions) {
            await tx.insert('recording_losses', {
              'record_key': record.key,
              'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
              'reason': 'pending byte budget exceeded',
            });
            await _advanceWatermark(tx, record);
          }
          return;
        }
        for (final record in additions) {
          await tx.insert('journal', {
            'record_key': record.key,
            'kind': record.kind.name,
            'session_uid': record.sessionId,
            'identity_number': record.identityNumber,
            'payload_json': record.payloadJson,
            'payload_bytes': utf8.encode(record.payloadJson).length,
            'enqueued_at_utc': DateTime.now().toUtc().toIso8601String(),
          });
          await _advanceWatermark(tx, record);
        }
        if (replaceCheckpoint) {
          await tx.delete('control_checkpoint');
          if (checkpointJson != null) {
            await tx.insert('control_checkpoint', {
              'id': 1,
              'json': checkpointJson,
            });
          }
        }
      });
      if (rejected) {
        spoolHealth.updateRecordingErrors(
          storage: 'Recording quota exceeded',
          rejected: records.length,
        );
        throw StateError('Pending telemetry byte budget exceeded');
      }
      spoolHealth.updateRecordingErrors(export: spoolHealth.exportError);
      await refreshHealth();
    } catch (error) {
      spoolHealth.updateRecordingErrors(
        storage: error.toString(),
        export: spoolHealth.exportError,
      );
      rethrow;
    }
  }

  Future<void> _advanceWatermark(
    DatabaseExecutor tx,
    TelemetryRecord record,
  ) async {
    final metric = record.kind == TelemetryRecordKind.metric;
    await tx.rawInsert(
      '''INSERT INTO session_watermarks(session_uid,sequence,revision)
      VALUES(?,?,?) ON CONFLICT(session_uid) DO UPDATE SET
      sequence=max(sequence,excluded.sequence),revision=max(revision,excluded.revision)''',
      [
        record.sessionId,
        metric ? record.identityNumber : 0,
        metric ? 0 : record.identityNumber,
      ],
    );
  }

  Future<List<PendingJournalRecord>> readPending({int limit = 32}) async {
    await initialize();
    final rows = await _db!.query(
      'journal',
      where: "delivery_state='pending'",
      orderBy: 'id',
      limit: limit,
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
          ),
        )
        .toList();
  }

  Future<void> markBrokerAcknowledged(List<int> ids) async {
    await initialize();
    await _db!.transaction((tx) async {
      for (final id in ids) {
        await tx.update(
          'journal',
          {
            'delivery_state': 'broker_acked',
            'broker_acked_at_utc': DateTime.now().toUtc().toIso8601String(),
            'last_error': null,
          },
          where: "id=? AND delivery_state='pending'",
          whereArgs: [id],
        );
      }
    });
    await refreshHealth();
  }

  Future<void> recordAttempt(List<int> ids, {String? error}) async {
    await initialize();
    await _db!.transaction((tx) async {
      for (final id in ids) {
        await tx.rawUpdate(
          'UPDATE journal SET attempt_count=attempt_count+1,last_error=? WHERE id=?',
          [error, id],
        );
      }
    });
  }

  Future<void> markDropped(int id, String reason) async {
    await initialize();
    await _db!.update(
      'journal',
      {'delivery_state': 'dropped', 'last_error': reason},
      where: "id=? AND delivery_state='pending'",
      whereArgs: [id],
    );
    spoolHealth.updateRecordingErrors(
      storage: reason,
      export: spoolHealth.exportError,
      rejected: 1,
    );
    await refreshHealth();
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

  Future<void> refreshHealth() async {
    final db = _db;
    if (db == null) return;
    final row = (await db.rawQuery(
      "SELECT count(*) AS count,min(enqueued_at_utc) AS oldest,"
      "COALESCE(sum(payload_bytes),0) AS bytes FROM journal WHERE delivery_state='pending'",
    )).single;
    spoolHealth.updateBacklog(
      count: row['count'] as int,
      oldestEnqueuedAtUtc: row['oldest'] == null
          ? null
          : DateTime.parse(row['oldest'] as String),
    );
    spoolHealth.updatePendingCapacity(
      pendingBytes: row['bytes'] as int,
      byteCapacity: maxPendingBytes,
    );
  }

  Future<void> flushExports() =>
      _exporting ??= _export().whenComplete(() => _exporting = null);
  Future<void> _export() async {
    await initialize();
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
      spoolHealth.updateRecordingErrors(storage: spoolHealth.storageError);
    } catch (error) {
      spoolHealth.updateRecordingErrors(
        storage: spoolHealth.storageError,
        export: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> prune({Duration history = const Duration(days: 7)}) async {
    await initialize();
    final cursor = (await _db!.query('export_state')).single['last_id'] as int;
    await _db!.delete(
      'journal',
      where:
          "delivery_state='broker_acked' AND broker_acked_at_utc<? AND id<=?",
      whereArgs: [
        DateTime.now().toUtc().subtract(history).toIso8601String(),
        cursor,
      ],
    );
  }

  Future<void> clearAllLocalStorage() async {
    await initialize();
    await _exporting;
    await _db!.transaction((tx) async {
      for (final table in [
        'journal',
        'control_checkpoint',
        'session_watermarks',
        'recording_losses',
      ]) {
        await tx.delete(table);
      }
      await tx.update('export_state', {'last_id': 0});
    });
    await _writer.clearAllFiles();
    spoolHealth.updateRecordingErrors();
    await refreshHealth();
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
    if (_db != null) {
      try {
        await flushExports();
      } catch (_) {
        /* Keep cursor for next restart. */
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
    spoolHealth.dispose();
  }
}
