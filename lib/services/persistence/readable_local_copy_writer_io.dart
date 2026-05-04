import 'dart:io';

import 'package:path/path.dart' as p;

class ReadableLocalCopyPreview {
  final String? directoryPath;
  final int fileCount;
  final List<String> recentLines;

  const ReadableLocalCopyPreview({
    required this.directoryPath,
    required this.fileCount,
    required this.recentLines,
  });

  static const empty = ReadableLocalCopyPreview(
    directoryPath: null,
    fileCount: 0,
    recentLines: <String>[],
  );
}

class ReadableLocalCopyWriter {
  static const List<String> _sessionCsvColumns = <String>[
    'ts_wall_utc',
    'ts_session_ms',
    'session_id',
    'lap_number',
    'session_state',
    'lap_phase',
    'metric_key',
    'metric_value',
    'unit',
    'source',
    'can_id',
    'seq_in_session',
    'quality_flag',
  ];

  int _maxFileBytes;

  Directory? _rootDirectory;

  ReadableLocalCopyWriter({int maxFileBytes = 4 * 1024 * 1024})
    : _maxFileBytes = maxFileBytes;

  String? get directoryPath => _rootDirectory?.path;

  String? get sessionCsvDirectoryPath {
    final root = _rootDirectory;
    if (root == null) {
      return null;
    }
    return p.join(root.path, 'session_csv');
  }

  void setMaxFileBytes(int value) {
    if (value <= 0) {
      return;
    }
    _maxFileBytes = value;
  }

  Future<void> initialize({
    required String? baseDirectoryPath,
    required String? overrideDirectoryPath,
  }) async {
    final override = overrideDirectoryPath?.trim();
    final resolvedPath = (override != null && override.isNotEmpty)
        ? override
        : (baseDirectoryPath == null || baseDirectoryPath.isEmpty)
        ? null
        : p.join(baseDirectoryPath, 'readable_local_copy');

    if (resolvedPath == null) {
      _rootDirectory = null;
      return;
    }

    final directory = Directory(resolvedPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _rootDirectory = directory;
  }

  Future<String?> appendSessionCsvRow({
    required String sessionId,
    required Map<String, Object?> row,
  }) async {
    final root = _rootDirectory;
    if (root == null) {
      return null;
    }

    final csvRoot = Directory(sessionCsvDirectoryPath!);
    if (!await csvRoot.exists()) {
      await csvRoot.create(recursive: true);
    }

    final nowUtc = DateTime.now().toUtc();
    final normalizedSessionId = _normalizeSessionId(
      sessionId.isEmpty ? 'pending-session' : sessionId,
    );
    final filePath = p.join(csvRoot.path, 'session_$normalizedSessionId.csv');
    final file = File(filePath);

    await _rotateIfNeeded(file, nowUtc: nowUtc);

    final exists = await file.exists();
    final shouldWriteHeader = !exists || (exists && await file.length() == 0);

    final buffer = StringBuffer();
    if (shouldWriteHeader) {
      buffer.writeln(_sessionCsvColumns.join(','));
    }

    final rowValues = _sessionCsvColumns
        .map((column) => _escapeCsvValue(row[column]))
        .join(',');
    buffer.writeln(rowValues);

    await file.writeAsString(
      buffer.toString(),
      mode: FileMode.append,
      flush: false,
    );
    return file.path;
  }

  Future<ReadableLocalCopyPreview> readPreview({
    int maxFiles = 6,
    int maxLinesPerFile = 8,
    int maxLineLength = 220,
  }) async {
    final root = _rootDirectory;
    if (root == null || !await root.exists()) {
      return ReadableLocalCopyPreview.empty;
    }

    final readableFiles = await _listReadableFiles(root);

    if (readableFiles.isEmpty) {
      return ReadableLocalCopyPreview(
        directoryPath: root.path,
        fileCount: 0,
        recentLines: const <String>[],
      );
    }

    final selectedFiles = readableFiles.take(maxFiles).toList(growable: false);
    final recentLines = <String>[];

    for (final file in selectedFiles) {
      final fileName = _relativeForPreview(root, file);
      try {
        final lines = await file.readAsLines();
        final start = lines.length > maxLinesPerFile
            ? lines.length - maxLinesPerFile
            : 0;
        for (int i = start; i < lines.length; i++) {
          recentLines.add(
            '$fileName | ${_truncateLine(lines[i], maxLineLength)}',
          );
        }
      } catch (_) {
        recentLines.add('$fileName | [failed to read file]');
      }
    }

    return ReadableLocalCopyPreview(
      directoryPath: root.path,
      fileCount: readableFiles.length,
      recentLines: recentLines,
    );
  }

  Future<String?> exportSnapshot({
    String? exportRootDirectoryPath,
    DateTime? nowUtc,
  }) async {
    final root = _rootDirectory;
    if (root == null || !await root.exists()) {
      return null;
    }

    final sourceFiles = await _listReadableFiles(root);

    if (sourceFiles.isEmpty) {
      return null;
    }

    final exportRootPath =
        (exportRootDirectoryPath != null &&
            exportRootDirectoryPath.trim().isNotEmpty)
        ? exportRootDirectoryPath.trim()
        : p.join(root.parent.path, 'readable_local_copy_exports');
    final exportRoot = Directory(exportRootPath);
    if (!await exportRoot.exists()) {
      await exportRoot.create(recursive: true);
    }

    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    final exportDirectory = Directory(
      p.join(exportRoot.path, 'export_${_exportStamp(now)}'),
    );
    await exportDirectory.create(recursive: true);

    for (final file in sourceFiles) {
      final relativePath = p.relative(file.path, from: root.path);
      final targetPath = p.join(exportDirectory.path, relativePath);
      final targetFile = File(targetPath);
      await targetFile.parent.create(recursive: true);
      await file.copy(targetFile.path);
    }

    final manifest = File(p.join(exportDirectory.path, 'manifest.txt'));
    final manifestContent = <String>[
      'created_at_utc=${now.toIso8601String()}',
      'source_directory=${root.path}',
      'file_count=${sourceFiles.length}',
    ].join('\n');
    await manifest.writeAsString(manifestContent, flush: true);

    return exportDirectory.path;
  }

  Future<void> pruneOlderThan(Duration maxAge) async {
    final root = _rootDirectory;
    if (root == null || !await root.exists()) {
      return;
    }

    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    final files = await _listReadableFiles(root);
    for (final entity in files) {
      final stat = await entity.stat();
      if (stat.modified.toUtc().isBefore(cutoff)) {
        await entity.delete();
      }
    }
  }

  Future<void> close() async {}

  Future<void> _rotateIfNeeded(File file, {required DateTime nowUtc}) async {
    if (!await file.exists()) {
      return;
    }

    final length = await file.length();
    if (length < _maxFileBytes) {
      return;
    }

    final baseName = p.basenameWithoutExtension(file.path);
    final extension = p.extension(file.path);
    final rotatedPath = p.join(
      file.parent.path,
      '${baseName}_${_exportStamp(nowUtc)}$extension',
    );
    await file.rename(rotatedPath);
  }

  Future<List<File>> _listReadableFiles(Directory root) async {
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (!_isReadableMirrorFile(entity.path)) {
        continue;
      }
      files.add(entity);
    }

    final fileTimes = <File, DateTime>{};
    for (final file in files) {
      try {
        final stat = await file.stat();
        fileTimes[file] = stat.modified.toUtc();
      } catch (_) {
        fileTimes[file] = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      }
    }

    files.sort((a, b) {
      final aTime = fileTimes[a]!;
      final bTime = fileTimes[b]!;
      final cmp = bTime.compareTo(aTime);
      if (cmp != 0) {
        return cmp;
      }
      return b.path.compareTo(a.path);
    });
    return files;
  }

  bool _isReadableMirrorFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.csv');
  }

  String _relativeForPreview(Directory root, File file) {
    final relative = p.relative(file.path, from: root.path);
    return relative.replaceAll('\\', '/');
  }

  String _normalizeSessionId(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  String _exportStamp(DateTime valueUtc) {
    final yyyy = valueUtc.year.toString().padLeft(4, '0');
    final mm = valueUtc.month.toString().padLeft(2, '0');
    final dd = valueUtc.day.toString().padLeft(2, '0');
    final hh = valueUtc.hour.toString().padLeft(2, '0');
    final min = valueUtc.minute.toString().padLeft(2, '0');
    final ss = valueUtc.second.toString().padLeft(2, '0');
    final ms = valueUtc.millisecond.toString().padLeft(3, '0');
    return '$yyyy$mm${dd}_$hh$min${ss}_$ms';
  }

  String _truncateLine(String line, int maxLength) {
    if (line.length <= maxLength) {
      return line;
    }
    return '${line.substring(0, maxLength)}...';
  }

  String _escapeCsvValue(Object? value) {
    if (value == null) {
      return '';
    }
    final text = value.toString();
    final requiresQuote =
        text.contains(',') ||
        text.contains('"') ||
        text.contains('\n') ||
        text.contains('\r');
    if (!requiresQuote) {
      return text;
    }
    final escaped = text.replaceAll('"', '""');
    return '"$escaped"';
  }
}
