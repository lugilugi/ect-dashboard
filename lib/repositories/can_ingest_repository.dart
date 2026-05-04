import 'dart:async';
import 'dart:isolate';

class CanFrameMessage {
  final int canId;
  final String payloadHex;
  final DateTime receivedAtUtc;
  final String source;

  const CanFrameMessage({
    required this.canId,
    required this.payloadHex,
    required this.receivedAtUtc,
    required this.source,
  });
}

class CanParseError {
  final String line;
  final String reason;
  final DateTime receivedAtUtc;
  final String source;

  const CanParseError({
    required this.line,
    required this.reason,
    required this.receivedAtUtc,
    required this.source,
  });
}

abstract class CanIngestRepository {
  Stream<CanFrameMessage> get frames;
  Stream<CanParseError> get parseErrors;

  Future<void> start();
  Future<void> ingestLine(String line, {required String source});
  Future<void> dispose();
}

class IsolateCanIngestRepository implements CanIngestRepository {
  final StreamController<CanFrameMessage> _framesController =
      StreamController<CanFrameMessage>.broadcast();
  final StreamController<CanParseError> _errorsController =
      StreamController<CanParseError>.broadcast();

  ReceivePort? _receivePort;
  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  Completer<void>? _readyCompleter;
  bool _disposed = false;

  @override
  Stream<CanFrameMessage> get frames => _framesController.stream;

  @override
  Stream<CanParseError> get parseErrors => _errorsController.stream;

  @override
  Future<void> start() async {
    if (_disposed) {
      return;
    }
    if (_workerSendPort != null) {
      return;
    }
    if (_readyCompleter != null) {
      return _readyCompleter!.future;
    }

    _readyCompleter = Completer<void>();
    _receivePort = ReceivePort();
    _receivePort!.listen(_onWorkerMessage);

    _workerIsolate = await Isolate.spawn<SendPort>(
      _canParserWorkerMain,
      _receivePort!.sendPort,
      errorsAreFatal: false,
    );

    await _readyCompleter!.future;
  }

  @override
  Future<void> ingestLine(String line, {required String source}) async {
    if (_disposed) {
      return;
    }

    await start();

    final sendPort = _workerSendPort;
    if (sendPort == null) {
      return;
    }

    sendPort.send(<String, Object?>{
      'type': 'line',
      'line': line,
      'source': source,
      'received_at_ms_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
  }

  void _onWorkerMessage(dynamic message) {
    if (message is SendPort) {
      _workerSendPort = message;
      final completer = _readyCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      return;
    }

    if (message is! Map) {
      return;
    }

    final type = message['type'];
    if (type == 'frame') {
      final canId = message['can_id'];
      final payloadHex = message['payload_hex'];
      final source = message['source'];
      final receivedAtMsUtc = message['received_at_ms_utc'];
      if (canId is int &&
          payloadHex is String &&
          source is String &&
          receivedAtMsUtc is int) {
        _framesController.add(
          CanFrameMessage(
            canId: canId,
            payloadHex: payloadHex,
            source: source,
            receivedAtUtc: DateTime.fromMillisecondsSinceEpoch(
              receivedAtMsUtc,
              isUtc: true,
            ),
          ),
        );
      }
      return;
    }

    if (type == 'parse_error') {
      final line = message['line'];
      final reason = message['reason'];
      final source = message['source'];
      final receivedAtMsUtc = message['received_at_ms_utc'];
      if (line is String &&
          reason is String &&
          source is String &&
          receivedAtMsUtc is int) {
        _errorsController.add(
          CanParseError(
            line: line,
            reason: reason,
            source: source,
            receivedAtUtc: DateTime.fromMillisecondsSinceEpoch(
              receivedAtMsUtc,
              isUtc: true,
            ),
          ),
        );
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;

    final sendPort = _workerSendPort;
    if (sendPort != null) {
      sendPort.send(const <String, Object?>{'type': 'shutdown'});
    }

    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerSendPort = null;

    _receivePort?.close();
    _receivePort = null;

    await _framesController.close();
    await _errorsController.close();
  }
}

void _canParserWorkerMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  final candumpRegex = RegExp(r'^can0\s+([0-9a-fA-F]+)#([0-9a-fA-F]*)$');

  receivePort.listen((dynamic message) {
    if (message is! Map) {
      return;
    }

    final type = message['type'];
    if (type == 'shutdown') {
      receivePort.close();
      return;
    }

    if (type != 'line') {
      return;
    }

    final line = message['line'];
    final source = message['source'];
    final receivedAtMsUtc = message['received_at_ms_utc'];

    if (line is! String || source is! String || receivedAtMsUtc is! int) {
      return;
    }

    final match = candumpRegex.firstMatch(line.trim());
    if (match == null) {
      return;
    }

    final idStr = match.group(1);
    final payloadHex = (match.group(2) ?? '').toLowerCase();
    if (idStr == null) {
      return;
    }

    final canId = int.tryParse(idStr, radix: 16);
    if (canId == null) {
      mainSendPort.send(<String, Object?>{
        'type': 'parse_error',
        'line': line,
        'reason': 'invalid_can_id',
        'source': source,
        'received_at_ms_utc': receivedAtMsUtc,
      });
      return;
    }

    mainSendPort.send(<String, Object?>{
      'type': 'frame',
      'can_id': canId,
      'payload_hex': payloadHex,
      'source': source,
      'received_at_ms_utc': receivedAtMsUtc,
    });
  });
}
