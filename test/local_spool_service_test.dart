import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';

void main() {
  group('LocalSpoolService (memory fallback)', () {
    test('enqueue and pending metadata are tracked', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      final now = DateTime.now().toUtc();
      await spool.enqueueBatch(
        topic: 'telemetry/a',
        payloadJson: '{"a":1}',
        enqueuedAtUtc: now.subtract(const Duration(seconds: 2)),
      );
      await spool.enqueueBatch(
        topic: 'telemetry/b',
        payloadJson: '{"b":2}',
        enqueuedAtUtc: now,
      );

      final pendingCount = await spool.pendingCount();
      final oldest = await spool.oldestPendingEnqueuedAtUtc();
      final pending = await spool.readPendingBatches(limit: 5);

      expect(pendingCount, 2);
      expect(oldest, isNotNull);
      expect(oldest!.isBefore(now), isTrue);
      expect(pending.length, 2);
      expect(pending.first.topic, 'telemetry/a');
      expect(pending.last.topic, 'telemetry/b');

      await spool.close();
    });

    test('markPublished removes record from pending list', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      final id = await spool.enqueueBatch(
        topic: 'telemetry/c',
        payloadJson: '{"c":3}',
      );

      await spool.markPublished(batchId: id);

      final pendingCount = await spool.pendingCount();
      final pending = await spool.readPendingBatches(limit: 5);

      expect(pendingCount, 0);
      expect(pending, isEmpty);

      await spool.close();
    });

    test('recordAttempt updates attempt metadata for pending record', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      final id = await spool.enqueueBatch(
        topic: 'telemetry/d',
        payloadJson: '{"d":4}',
      );

      await spool.recordAttempt(batchId: id, outcome: 'send_failed');

      final pending = await spool.readPendingBatches(limit: 5);

      expect(pending.length, 1);
      expect(pending.first.attemptCount, 1);
      expect(pending.first.lastAttemptAtUtc, isNotNull);

      await spool.close();
    });

    test('decoded events are deduplicated by session and sequence', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      await spool.enqueueDecodedEvent(
        sessionId: 'session-1',
        seqInSession: 12,
        eventJson: '{"metric_key":"Speed_Kmh"}',
      );
      await spool.enqueueDecodedEvent(
        sessionId: 'session-1',
        seqInSession: 12,
        eventJson: '{"metric_key":"Speed_Kmh"}',
      );

      final pendingDecoded = await spool.pendingDecodedEventCount();
      expect(pendingDecoded, 1);

      await spool.close();
    });

    test('max decoded sequence returns per-session high watermark', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      await spool.enqueueDecodedEvent(
        sessionId: 'session-1',
        seqInSession: 4,
        eventJson: '{"metric_key":"A"}',
      );
      await spool.enqueueDecodedEvent(
        sessionId: 'session-1',
        seqInSession: 11,
        eventJson: '{"metric_key":"B"}',
      );
      await spool.enqueueDecodedEvent(
        sessionId: 'session-2',
        seqInSession: 99,
        eventJson: '{"metric_key":"C"}',
      );

      await spool.markDecodedEventsPublishedRange(
        sessionId: 'session-1',
        seqInSessionStart: 11,
        seqInSessionEnd: 11,
      );

      expect(await spool.maxDecodedSequenceForSession('session-1'), 11);
      expect(await spool.maxDecodedSequenceForSession('session-2'), 99);
      expect(await spool.maxDecodedSequenceForSession('missing'), 0);
      expect(await spool.maxDecodedSequenceForSession(''), 0);

      await spool.close();
    });

    test(
      'markDecodedEventsPublishedRange marks only requested range',
      () async {
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 10,
        );

        await spool.initialize();

        await spool.enqueueDecodedEvent(
          sessionId: 'session-2',
          seqInSession: 10,
          eventJson: '{"metric_key":"A"}',
        );
        await spool.enqueueDecodedEvent(
          sessionId: 'session-2',
          seqInSession: 11,
          eventJson: '{"metric_key":"B"}',
        );
        await spool.enqueueDecodedEvent(
          sessionId: 'session-2',
          seqInSession: 12,
          eventJson: '{"metric_key":"C"}',
        );

        await spool.markDecodedEventsPublishedRange(
          sessionId: 'session-2',
          seqInSessionStart: 10,
          seqInSessionEnd: 11,
        );

        final pendingDecoded = await spool.pendingDecodedEventCount();
        expect(pendingDecoded, 1);

        await spool.close();
      },
    );

    test('raw frame insert and age pruning are bounded', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      await spool.enqueueRawFrame(
        sessionId: 'session-3',
        tsSessionMs: 1000,
        canId: 0x110,
        payloadHex: 'AA55',
        source: 'usb',
        tsWallUtc: DateTime.now().toUtc().subtract(const Duration(days: 3)),
      );
      await spool.enqueueRawFrame(
        sessionId: 'session-3',
        tsSessionMs: 2000,
        canId: 0x310,
        payloadHex: 'BB66',
        source: 'usb',
      );

      expect(await spool.rawFrameCount(), 2);

      await spool.pruneRawFramesOlderThan(const Duration(days: 1));
      expect(await spool.rawFrameCount(), 1);

      await spool.close();
    });

    test('session checkpoint can be saved, read, and cleared', () async {
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 10,
      );

      await spool.initialize();

      await spool.saveSessionCheckpoint(
        checkpointJson: '{"session_id":"session-checkpoint-1"}',
      );

      final saved = await spool.readSessionCheckpointJson();
      expect(saved, '{"session_id":"session-checkpoint-1"}');

      await spool.clearSessionCheckpoint();
      final cleared = await spool.readSessionCheckpointJson();
      expect(cleared, isNull);

      await spool.close();
    });

    test('writes decoded telemetry into per-session CSV files', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ect-readable-copy-test-',
      );

      try {
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 10,
          readableCopyEnabled: true,
          readableCopyDirectoryPath: tempDir.path,
        );

        await spool.initialize();

        final batchId = await spool.enqueueBatch(
          topic: 'telemetry/readable',
          payloadJson: '{"metric":"Speed_Kmh","value":12.3}',
          sessionId: 'session-readable-1',
        );
        await spool.recordAttempt(
          batchId: batchId,
          outcome: 'sent',
          incrementAttemptCounter: true,
        );
        await spool.markPublished(batchId: batchId);
        await spool.enqueueDecodedEvent(
          sessionId: 'session-readable-1',
          seqInSession: 1,
          eventJson: '{"metric_key":"Speed_Kmh","metric_value":12.3}',
        );
        await spool.enqueueRawFrame(
          sessionId: 'session-readable-1',
          tsSessionMs: 1000,
          canId: 0x500,
          payloadHex: 'A1B2C3D4',
          source: 'usb',
        );

        final mirrorPath = spool.readableCopyPath;
        expect(mirrorPath, isNotNull);
        expect(mirrorPath, tempDir.path);

        final files = await Directory(
          mirrorPath!,
        ).list(recursive: true).toList();
        final csvFiles = files.whereType<File>().where((file) {
          return file.path.toLowerCase().endsWith('.csv');
        }).toList();

        expect(csvFiles.isNotEmpty, isTrue);

        final allContent = await csvFiles.first.readAsString();

        expect(allContent, contains('session-readable-1'));
        expect(allContent, contains('metric_key'));
        expect(allContent, contains('Speed_Kmh'));

        await spool.close();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('reads readable mirror preview lines', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ect-readable-preview-test-',
      );

      try {
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 10,
          readableCopyEnabled: true,
          readableCopyDirectoryPath: tempDir.path,
        );

        await spool.initialize();
        await spool.enqueueBatch(
          topic: 'telemetry/preview',
          payloadJson: '{"metric":"Speed_Kmh","value":18.2}',
          sessionId: 'session-preview-1',
        );
        await spool.enqueueDecodedEvent(
          sessionId: 'session-preview-1',
          seqInSession: 1,
          eventJson: '{"metric_key":"Speed_Kmh","metric_value":18.2}',
        );

        final preview = await spool.readReadableCopyPreview(
          maxFiles: 6,
          maxLinesPerFile: 4,
          maxLineLength: 180,
        );

        expect(preview.directoryPath, tempDir.path);
        expect(preview.fileCount, greaterThan(0));
        expect(preview.recentLines.join('\n'), contains('session-preview-1'));
        expect(preview.recentLines.join('\n'), contains('Speed_Kmh'));

        await spool.close();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('exports readable mirror snapshot to export folder', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ect-readable-export-test-',
      );

      try {
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 10,
          readableCopyEnabled: true,
          readableCopyDirectoryPath: tempDir.path,
        );

        await spool.initialize();
        await spool.enqueueBatch(
          topic: 'telemetry/export',
          payloadJson: '{"metric":"Distance_Km","value":2.5}',
          sessionId: 'session-export-1',
        );
        await spool.enqueueDecodedEvent(
          sessionId: 'session-export-1',
          seqInSession: 1,
          eventJson: '{"metric_key":"Distance_Km","metric_value":2.5}',
        );

        final exportPath = await spool.exportReadableCopy();
        expect(exportPath, isNotNull);

        final exportDirectory = Directory(exportPath!);
        expect(await exportDirectory.exists(), isTrue);

        final exportedFiles = await exportDirectory
            .list(recursive: true)
            .toList();
        final exportedCsv = exportedFiles.whereType<File>().where((file) {
          return file.path.toLowerCase().endsWith('.csv');
        }).toList();
        final exportedJsonl = exportedFiles.whereType<File>().where((file) {
          return file.path.toLowerCase().endsWith('.jsonl') ||
              file.path.toLowerCase().endsWith('.ndjson');
        }).toList();
        expect(exportedCsv.isNotEmpty, isTrue);
        expect(exportedJsonl, isEmpty);
        expect(
          exportedFiles.any(
            (entity) => entity is File && entity.path.endsWith('manifest.txt'),
          ),
          isTrue,
        );

        await spool.close();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
