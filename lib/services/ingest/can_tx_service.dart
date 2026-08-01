import 'dart:async';

import 'package:telemetry_dashboard/models/telemetry/tx_can_command.dart';
import 'package:telemetry_dashboard/services/ingest/command_dictionary_service.dart';

enum TxCommandStatus {
  acked,
  nacked,
  timeout,
  rejected,
}

class TxCommandResult {
  final TxCommandStatus status;
  final int? sequence;
  final int retries;
  final String? reason;
  final TxCanCommand command;

  const TxCommandResult({
    required this.status,
    required this.sequence,
    required this.retries,
    required this.reason,
    required this.command,
  });
}

class _PendingCommand {
  final TxCanCommand command;
  final int sequence;
  final String frameBody;
  final String frame;
  final Completer<TxCommandResult> completer;
  int retries;
  Timer? timeoutTimer;

  _PendingCommand({
    required this.command,
    required this.sequence,
    required this.frameBody,
    required this.frame,
    required this.completer,
    required this.retries,
  });
}

class CanTxService {
  final CommandDictionaryService dictionaryService;
  final void Function(String frame) sendRawFrame;
  final void Function(TxCommandResult result)? onResult;
  final bool Function()? isDriverMode;
  final bool Function()? isLogging;
  final Duration ackTimeout;
  final int maxRetries;

  final Map<int, _PendingCommand> _pendingBySequence = <int, _PendingCommand>{};
  int _sequence = 0;

  CanTxService({
    required this.dictionaryService,
    required this.sendRawFrame,
    this.onResult,
    this.isDriverMode,
    this.isLogging,
    this.ackTimeout = const Duration(milliseconds: 350),
    this.maxRetries = 2,
  });

  Future<TxCommandResult> sendCommand(TxCanCommand command) {
    final validation = dictionaryService.validate(command);
    if (!validation.accepted) {
      final rejected = TxCommandResult(
        status: TxCommandStatus.rejected,
        sequence: null,
        retries: 0,
        reason: validation.reason,
        command: command,
      );
      onResult?.call(rejected);
      return Future<TxCommandResult>.value(rejected);
    }

    final definition = validation.definition!;
    final inDriverMode = isDriverMode?.call() ?? true;
    final loggingActive = isLogging?.call() ?? false;
    if (inDriverMode &&
        loggingActive &&
        definition.safetyClass == CanTxSafetyClass.maintenance) {
      final rejected = TxCommandResult(
        status: TxCommandStatus.rejected,
        sequence: null,
        retries: 0,
        reason: 'blocked_in_driver_logging_mode',
        command: command,
      );
      onResult?.call(rejected);
      return Future<TxCommandResult>.value(rejected);
    }

    _sequence = (_sequence + 1) & 0x7FFFFFFF;
    if (_sequence == 0) {
      _sequence = 1;
    }

    final commandCodeHex = definition.commandCode.toRadixString(16).padLeft(2, '0').toUpperCase();
    final argsHex = command.args
        .map((arg) => arg.toRadixString(16).toUpperCase())
        .toList(growable: false);

    final frameSegments = <String>[
      'C',
      'v1',
      _sequence.toString(),
      commandCodeHex,
      ...argsHex,
    ];
    final frameBody = frameSegments.join('|');
    final crc = _crc16Hex(frameBody);
    final frame = '$frameBody|$crc\n';

    final completer = Completer<TxCommandResult>();
    final pending = _PendingCommand(
      command: command,
      sequence: _sequence,
      frameBody: frameBody,
      frame: frame,
      completer: completer,
      retries: 0,
    );

    _pendingBySequence[pending.sequence] = pending;
    _sendPending(pending);
    return completer.future;
  }

  void handleIncomingLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('A|v1|')) {
      return;
    }

    final parts = trimmed.split('|');
    if (parts.length < 6) {
      return;
    }

    final seq = int.tryParse(parts[2]);
    if (seq == null) {
      return;
    }

    final status = parts[3].toLowerCase();
    final err = parts[4];
    final crc = parts[5].toUpperCase();

    final crcBody = parts.sublist(0, 5).join('|');
    final expectedCrc = _crc16Hex(crcBody);
    if (crc != expectedCrc) {
      return;
    }

    final pending = _pendingBySequence.remove(seq);
    if (pending == null) {
      return;
    }

    pending.timeoutTimer?.cancel();

    final result = TxCommandResult(
      status: status == 'ok' ? TxCommandStatus.acked : TxCommandStatus.nacked,
      sequence: seq,
      retries: pending.retries,
      reason: status == 'ok' ? null : err,
      command: pending.command,
    );

    if (!pending.completer.isCompleted) {
      pending.completer.complete(result);
    }
    onResult?.call(result);
  }

  void dispose() {
    for (final pending in _pendingBySequence.values) {
      pending.timeoutTimer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          TxCommandResult(
            status: TxCommandStatus.timeout,
            sequence: pending.sequence,
            retries: pending.retries,
            reason: 'service_disposed',
            command: pending.command,
          ),
        );
      }
    }
    _pendingBySequence.clear();
  }

  void _sendPending(_PendingCommand pending) {
    sendRawFrame(pending.frame);

    pending.timeoutTimer?.cancel();
    pending.timeoutTimer = Timer(ackTimeout, () {
      final stillPending = _pendingBySequence[pending.sequence];
      if (stillPending == null) {
        return;
      }

      if (stillPending.retries < maxRetries) {
        stillPending.retries += 1;
        _sendPending(stillPending);
        return;
      }

      _pendingBySequence.remove(stillPending.sequence);
      final timeoutResult = TxCommandResult(
        status: TxCommandStatus.timeout,
        sequence: stillPending.sequence,
        retries: stillPending.retries,
        reason: 'ack_timeout',
        command: stillPending.command,
      );

      if (!stillPending.completer.isCompleted) {
        stillPending.completer.complete(timeoutResult);
      }
      onResult?.call(timeoutResult);
    });
  }

  static String _crc16Hex(String value) {
    int crc = 0xFFFF;
    final bytes = value.codeUnits;

    for (final byte in bytes) {
      crc ^= (byte & 0xFF) << 8;
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    return crc.toRadixString(16).padLeft(4, '0').toUpperCase();
  }
}
