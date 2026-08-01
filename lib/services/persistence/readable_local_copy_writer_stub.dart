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
  int maxFileBytes;

  ReadableLocalCopyWriter({this.maxFileBytes = 4 * 1024 * 1024});

  String? get directoryPath => null;

  String? get sessionCsvDirectoryPath => null;

  void setMaxFileBytes(int value) {
    if (value > 0) {
      maxFileBytes = value;
    }
  }

  Future<void> initialize({
    required String? baseDirectoryPath,
    required String? overrideDirectoryPath,
  }) async {}

  Future<String?> appendSessionCsvRow({
    required String sessionId,
    required Map<String, Object?> row,
  }) async {
    return null;
  }

  Future<ReadableLocalCopyPreview> readPreview({
    int maxFiles = 6,
    int maxLinesPerFile = 8,
    int maxLineLength = 220,
  }) async {
    return ReadableLocalCopyPreview.empty;
  }

  Future<String?> exportSnapshot({
    String? exportRootDirectoryPath,
    DateTime? nowUtc,
  }) async {
    return null;
  }

  Future<void> pruneOlderThan(Duration maxAge) async {}

  Future<void> clearAllFiles() async {}

  Future<void> close() async {}
}
