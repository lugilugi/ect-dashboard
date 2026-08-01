import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/telemetry/tx_can_command.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/ingest/command_dictionary_service.dart';

String _crc16Hex(String value) {
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

void main() {
  group('CanTxService', () {
    test('encodes command and resolves on ACK', () async {
      final sentFrames = <String>[];
      final dictionary = CommandDictionaryService();

      final service = CanTxService(
        dictionaryService: dictionary,
        sendRawFrame: (frame) {
          sentFrames.add(frame);
        },
        ackTimeout: const Duration(milliseconds: 100),
      );

      final command = TxCanCommand(
        commandKey: 'LEFT_TURN_TOGGLE',
        args: const <int>[],
        targetCanId: CommandDictionaryService.auxControlCanId,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.operational,
      );

      final future = service.sendCommand(command);
      expect(sentFrames.length, 1);
      expect(sentFrames.first.startsWith('C|v1|1|10|'), isTrue);

      const ackBody = 'A|v1|1|ok|none';
      final ackLine = '$ackBody|${_crc16Hex(ackBody)}';
      service.handleIncomingLine(ackLine);
      final result = await future.timeout(const Duration(milliseconds: 300));

      expect(result.status, TxCommandStatus.acked);
      expect(result.sequence, 1);
      expect(result.retries, 0);
      service.dispose();
    });

    test('retries then times out without ACK', () async {
      final sentFrames = <String>[];
      final dictionary = CommandDictionaryService();

      final service = CanTxService(
        dictionaryService: dictionary,
        sendRawFrame: (frame) {
          sentFrames.add(frame);
        },
        ackTimeout: const Duration(milliseconds: 40),
        maxRetries: 1,
      );

      final command = TxCanCommand(
        commandKey: 'RIGHT_TURN_TOGGLE',
        args: const <int>[],
        targetCanId: CommandDictionaryService.auxControlCanId,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.operational,
      );

      final result = await service
          .sendCommand(command)
          .timeout(const Duration(milliseconds: 300));

      expect(result.status, TxCommandStatus.timeout);
      expect(result.retries, 1);
      expect(sentFrames.length, 2);
      service.dispose();
    });

    test('allows operational command in driver logging mode', () async {
      final sentFrames = <String>[];
      final dictionary = CommandDictionaryService();

      final service = CanTxService(
        dictionaryService: dictionary,
        sendRawFrame: (frame) {
          sentFrames.add(frame);
        },
        isDriverMode: () => true,
        isLogging: () => true,
        ackTimeout: const Duration(milliseconds: 40),
        maxRetries: 0,
      );

      final command = TxCanCommand(
        commandKey: 'HEADLIGHTS_TOGGLE',
        args: const <int>[],
        targetCanId: CommandDictionaryService.auxControlCanId,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.operational,
      );

      final result = await service
          .sendCommand(command)
          .timeout(const Duration(milliseconds: 300));

      expect(result.status, isNot(TxCommandStatus.rejected));
      expect(sentFrames.length, 1);
      expect(sentFrames.first.startsWith('C|v1|1|12|'), isTrue);
      service.dispose();
    });

    test('rejects maintenance command in driver logging mode', () async {
      final dictionary = _MaintenanceDictionary();

      final service = CanTxService(
        dictionaryService: dictionary,
        sendRawFrame: (_) {},
        isDriverMode: () => true,
        isLogging: () => true,
      );

      final command = TxCanCommand(
        commandKey: 'SET_CONFIG',
        args: const <int>[],
        targetCanId: 0x210,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.maintenance,
      );

      final result = await service.sendCommand(command);
      expect(result.status, TxCommandStatus.rejected);
      expect(result.reason, 'blocked_in_driver_logging_mode');
      service.dispose();
    });

    test('allows maintenance command when not logging', () async {
      final sentFrames = <String>[];
      final dictionary = _MaintenanceDictionary();

      final service = CanTxService(
        dictionaryService: dictionary,
        sendRawFrame: (frame) {
          sentFrames.add(frame);
        },
        isDriverMode: () => true,
        isLogging: () => false,
        ackTimeout: const Duration(milliseconds: 40),
        maxRetries: 0,
      );

      final command = TxCanCommand(
        commandKey: 'SET_CONFIG',
        args: const <int>[],
        targetCanId: 0x210,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.maintenance,
      );

      final result = await service
          .sendCommand(command)
          .timeout(const Duration(milliseconds: 300));

      expect(result.status, isNot(TxCommandStatus.rejected));
      expect(sentFrames.length, 1);
      service.dispose();
    });
  });
}

class _MaintenanceDictionary extends CommandDictionaryService {
  static const maintenanceDefinition = CommandDefinition(
    key: 'SET_CONFIG',
    commandCode: 0x20,
    targetCanId: 0x210,
    argSchema: <CommandArgSchema>[],
    safetyClass: CanTxSafetyClass.maintenance,
  );

  @override
  CommandValidationResult validate(TxCanCommand command) {
    if (command.commandKey == 'SET_CONFIG') {
      return const CommandValidationResult(
        accepted: true,
        reason: null,
        definition: maintenanceDefinition,
      );
    }
    return super.validate(command);
  }
}
