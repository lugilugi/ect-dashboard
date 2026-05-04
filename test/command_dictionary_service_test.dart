import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/telemetry/tx_can_command.dart';
import 'package:telemetry_dashboard/services/ingest/command_dictionary_service.dart';

void main() {
  group('CommandDictionaryService', () {
    test('accepts valid command and args', () {
      final dictionary = CommandDictionaryService();
      final cmd = TxCanCommand(
        commandKey: 'HORN_PULSE_MS',
        args: const <int>[500],
        targetCanId: CommandDictionaryService.auxControlCanId,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.operational,
      );

      final result = dictionary.validate(cmd);
      expect(result.accepted, isTrue);
      expect(result.definition, isNotNull);
      expect(result.reason, isNull);
    });

    test('rejects out-of-range args', () {
      final dictionary = CommandDictionaryService();
      final cmd = TxCanCommand(
        commandKey: 'HORN_PULSE_MS',
        args: const <int>[5000],
        targetCanId: CommandDictionaryService.auxControlCanId,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.operational,
      );

      final result = dictionary.validate(cmd);
      expect(result.accepted, isFalse);
      expect(result.reason, contains('arg_out_of_range'));
    });

    test('rejects unknown command key', () {
      final dictionary = CommandDictionaryService();
      final cmd = TxCanCommand(
        commandKey: 'UNKNOWN_CMD',
        args: const <int>[],
        targetCanId: 0x210,
        issuedAtMsUtc: DateTime.now().millisecondsSinceEpoch,
        source: 'test',
        safetyTag: CanTxSafetyClass.operational,
      );

      final result = dictionary.validate(cmd);
      expect(result.accepted, isFalse);
      expect(result.reason, 'unknown_command_key');
    });
  });
}
