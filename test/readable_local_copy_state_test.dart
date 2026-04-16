import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/readable_local_copy_writer.dart';

void main() {
  group('DashboardState readable local mirror controls', () {
    test('retention days clamp and callback dispatch', () async {
      final state = DashboardState();
      final received = <int>[];
      final completer = Completer<void>();

      state.onReadableCopyRetentionDaysChanged = (days) async {
        received.add(days);
        if (!completer.isCompleted) {
          completer.complete();
        }
      };

      state.setReadableCopyRetentionDays(0);
      await completer.future.timeout(const Duration(seconds: 1));

      expect(state.readableCopyRetentionDays, 1);
      expect(received, <int>[1]);

      state.dispose();
    });

    test('max file size clamp and callback dispatch', () async {
      final state = DashboardState();
      final received = <int>[];
      final completer = Completer<void>();

      state.onReadableCopyMaxFileBytesChanged = (value) async {
        received.add(value);
        if (!completer.isCompleted) {
          completer.complete();
        }
      };

      state.setReadableCopyMaxFileBytes(40 * 1024);
      await completer.future.timeout(const Duration(seconds: 1));

      expect(state.readableCopyMaxFileBytes, 128 * 1024);
      expect(received, <int>[128 * 1024]);

      state.dispose();
    });

    test('refresh preview updates directory file count and lines', () async {
      final state = DashboardState();
      state.onRequestReadableCopyPreview = () async {
        return const ReadableLocalCopyPreview(
          directoryPath: 'C:/tmp/readable_local_copy',
          fileCount: 3,
          recentLines: <String>['line-a', 'line-b'],
        );
      };

      await state.refreshReadableCopyPreview();

      expect(state.readableCopyPreviewLoading, isFalse);
      expect(state.readableCopyDirectoryPath, 'C:/tmp/readable_local_copy');
      expect(state.readableCopyFileCount, 3);
      expect(state.readableCopyRecentLines.length, 2);
      expect(state.readableCopyRecentLines.first, 'line-a');
      expect(state.readableCopyLastUpdatedAtUtc, isNotNull);

      state.dispose();
    });

    test('export snapshot stores latest export path', () async {
      final state = DashboardState();
      state.onRequestReadableCopyExport = () async {
        return 'C:/tmp/readable_local_copy_exports/export_1';
      };

      await state.exportReadableCopySnapshot();

      expect(
        state.readableCopyLastExportPath,
        'C:/tmp/readable_local_copy_exports/export_1',
      );
      expect(state.readableCopyPreviewError, isNull);

      state.dispose();
    });
  });
}
