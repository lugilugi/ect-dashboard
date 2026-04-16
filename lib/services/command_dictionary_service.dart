import '../models/tx_can_command.dart';

class CommandArgSchema {
  final String name;
  final int min;
  final int max;

  const CommandArgSchema({
    required this.name,
    required this.min,
    required this.max,
  });

  bool contains(int value) {
    return value >= min && value <= max;
  }
}

class CommandDefinition {
  final String key;
  final int commandCode;
  final int targetCanId;
  final List<CommandArgSchema> argSchema;
  final CanTxSafetyClass safetyClass;

  const CommandDefinition({
    required this.key,
    required this.commandCode,
    required this.targetCanId,
    required this.argSchema,
    required this.safetyClass,
  });
}

class CommandValidationResult {
  final bool accepted;
  final String? reason;
  final CommandDefinition? definition;

  const CommandValidationResult({
    required this.accepted,
    required this.reason,
    required this.definition,
  });
}

class CommandDictionaryService {
  static const int auxControlCanId = 0x210;

  final Map<String, CommandDefinition> _definitions = {
    'EMERGENCY_STOP': const CommandDefinition(
      key: 'EMERGENCY_STOP',
      commandCode: 0x01,
      targetCanId: 0x100,
      argSchema: <CommandArgSchema>[],
      safetyClass: CanTxSafetyClass.emergency,
    ),
    'LEFT_TURN_TOGGLE': const CommandDefinition(
      key: 'LEFT_TURN_TOGGLE',
      commandCode: 0x10,
      targetCanId: auxControlCanId,
      argSchema: <CommandArgSchema>[],
      safetyClass: CanTxSafetyClass.operational,
    ),
    'RIGHT_TURN_TOGGLE': const CommandDefinition(
      key: 'RIGHT_TURN_TOGGLE',
      commandCode: 0x11,
      targetCanId: auxControlCanId,
      argSchema: <CommandArgSchema>[],
      safetyClass: CanTxSafetyClass.operational,
    ),
    'HEADLIGHTS_TOGGLE': const CommandDefinition(
      key: 'HEADLIGHTS_TOGGLE',
      commandCode: 0x12,
      targetCanId: auxControlCanId,
      argSchema: <CommandArgSchema>[],
      safetyClass: CanTxSafetyClass.operational,
    ),
    'WIPERS_TOGGLE': const CommandDefinition(
      key: 'WIPERS_TOGGLE',
      commandCode: 0x13,
      targetCanId: auxControlCanId,
      argSchema: <CommandArgSchema>[],
      safetyClass: CanTxSafetyClass.operational,
    ),
    'HORN_PULSE_MS': const CommandDefinition(
      key: 'HORN_PULSE_MS',
      commandCode: 0x14,
      targetCanId: auxControlCanId,
      argSchema: <CommandArgSchema>[
        CommandArgSchema(name: 'duration_ms', min: 50, max: 3000),
      ],
      safetyClass: CanTxSafetyClass.operational,
    ),
    'HAZARDS_TOGGLE': const CommandDefinition(
      key: 'HAZARDS_TOGGLE',
      commandCode: 0x15,
      targetCanId: auxControlCanId,
      argSchema: <CommandArgSchema>[],
      safetyClass: CanTxSafetyClass.operational,
    ),
  };

  Iterable<CommandDefinition> get definitions => _definitions.values;

  CommandDefinition? definitionFor(String commandKey) {
    return _definitions[commandKey];
  }

  CommandValidationResult validate(TxCanCommand command) {
    final definition = definitionFor(command.commandKey);
    if (definition == null) {
      return const CommandValidationResult(
        accepted: false,
        reason: 'unknown_command_key',
        definition: null,
      );
    }

    if (command.args.length != definition.argSchema.length) {
      return CommandValidationResult(
        accepted: false,
        reason: 'invalid_arg_count',
        definition: definition,
      );
    }

    for (int i = 0; i < definition.argSchema.length; i++) {
      final schema = definition.argSchema[i];
      final value = command.args[i];
      if (!schema.contains(value)) {
        return CommandValidationResult(
          accepted: false,
          reason: 'arg_out_of_range:${schema.name}',
          definition: definition,
        );
      }
    }

    if (command.targetCanId != null && command.targetCanId != definition.targetCanId) {
      return CommandValidationResult(
        accepted: false,
        reason: 'target_can_mismatch',
        definition: definition,
      );
    }

    return CommandValidationResult(
      accepted: true,
      reason: null,
      definition: definition,
    );
  }
}
