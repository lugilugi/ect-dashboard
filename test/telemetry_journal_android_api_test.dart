import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    'Android journal opens and retains pending records across restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ect-android-db-',
      );
      const channel = MethodChannel('com.tekartik.sqflite');
      final nativeDatabases = <int, Database>{};
      var nextId = 0;

      // Exercise the real mobile sqflite client over its OS boundary. Real SQLite
      // stores the data; this bridge enforces Android execSQL's query restriction,
      // which the desktop FFI execute implementation does not enforce.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = (call.arguments as Map).cast<String, Object?>();
            if (call.method == 'openDatabase') {
              final id = ++nextId;
              nativeDatabases[id] = await databaseFactoryFfi.openDatabase(
                arguments['path'] as String,
                options: OpenDatabaseOptions(singleInstance: false),
              );
              return {'id': id};
            }
            final database = nativeDatabases[arguments['id'] as int]!;
            if (call.method == 'closeDatabase') {
              await database.close();
              nativeDatabases.remove(arguments['id']);
              return null;
            }
            Future<Object?> run(String method, Map<Object?, Object?> op) async {
              final sql = op['sql'] as String;
              final parameters = (op['arguments'] as List?)?.cast<Object?>();
              switch (method) {
                case 'execute':
                  if (RegExp(
                    r'^\s*(SELECT\b|PRAGMA\s+journal_mode\b)',
                    caseSensitive: false,
                  ).hasMatch(sql)) {
                    throw PlatformException(
                      code: 'sqlite_error',
                      message:
                          'Queries can be performed using SQLiteDatabase query '
                          'or rawQuery methods only.',
                      details: {'sql': sql, 'arguments': parameters},
                    );
                  }
                  await database.execute(sql, parameters);
                  return null;
                case 'query':
                  return database.rawQuery(sql, parameters);
                case 'insert':
                  final id = await database.rawInsert(sql, parameters);
                  // Android SQLiteStatement.executeInsert returns -1 when an
                  // INSERT OR IGNORE changed no row.
                  return id <= 0 ? -1 : id;
                case 'update':
                  return database.rawUpdate(sql, parameters);
                default:
                  throw MissingPluginException(method);
              }
            }

            if (call.method == 'batch') {
              final results = <Object?>[];
              for (final op in (arguments['operations'] as List)) {
                final operation = (op as Map).cast<Object?, Object?>();
                results.add({
                  'result': await run(operation['method'] as String, operation),
                });
              }
              return arguments['noResult'] == true ? null : results;
            }
            return run(call.method, arguments);
          });

      TelemetryJournal? journal;
      addTearDown(() async {
        await journal?.close();
        for (final database in nativeDatabases.values.toList()) {
          await database.close();
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      TelemetryJournal openJournal() => TelemetryJournal(
        databasePath: '${directory.path}/journal.db',
        factory: databaseFactorySqflitePlugin,
        readableCopyEnabled: false,
      );
      journal = openJournal();
      await journal.initialize();
      final record = TelemetryRecord.session({
        'schema_version': 2,
        'uid': '11111111-1111-4111-8111-111111111111',
        'metadata_revision': 1,
        'session_name': 'Android recording',
        'started_at_utc': '2026-10-07T00:00:00Z',
        'session_state': 'LOGGING',
        'laps_completed': 0,
      });
      await journal.appendRecords([record]);
      expect(journal.spoolHealth.storageError, isNull);
      expect(
        (await journal.readPending()).single.record.payload,
        record.payload,
      );
      // Retried identical record: the ignored insert reports -1 on Android.
      final retry = await journal.appendRecords([record]);
      expect(retry.stored, 0);
      expect(retry.duplicates, 1);
      expect(retry.conflicts, isEmpty);
      expect(journal.pendingCount, 1);
      await journal.close();
      journal = openJournal();
      expect(
        (await journal.readPending()).single.record.payload,
        record.payload,
      );
      expect(journal.spoolHealth.storageError, isNull);
      expect(journal.pendingCount, 1);
      final id = (await journal.readPending()).single.id;
      await journal.recordDeliveryRound(acked: [id]);
      expect(await journal.readPending(), isEmpty);
      expect(journal.pendingCount, 0);
      expect(journal.pendingBytes, 0);
    },
  );
}
