import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';

class CanDictionaryEntry {
  final int canId;
  final String key;
  final String label;
  final int expectedDlc;
  final int? cycleTimeMs;
  final String direction;
  final String decodeNotes;

  const CanDictionaryEntry({
    required this.canId,
    required this.key,
    required this.label,
    required this.expectedDlc,
    required this.cycleTimeMs,
    required this.direction,
    required this.decodeNotes,
  });

  String get hexId =>
      '0x${canId.toRadixString(16).toUpperCase().padLeft(3, '0')}';
}

/// Application view of the generated DBC message catalog. Wire facts come
/// from [CanDatabase]; labels are intentionally UI-facing conveniences.
abstract final class CanDictionary {
  static const Map<String, String> _labels = <String, String>{
    'PEDAL_STATUS': 'Pedal Status',
    'AUX_COMMAND': 'Auxiliary Command',
    'PACK_POWER': 'Pack Power',
    'AUX_POWER': 'Auxiliary Power',
    'PACK_ENERGY': 'Pack Energy',
    'VEHICLE_MOTION': 'Vehicle Motion',
    'VEHICLE_TIME': 'Vehicle Time',
    'GPS_STATUS': 'GPS Status',
    'GPS_POSITION': 'GPS Position',
    'GPS_MOTION': 'GPS Motion',
    'MOTOR_STATE': 'Motor State',
    'MOTOR_CURRENT': 'Motor Current',
    'MOTOR_VOLTAGE': 'Motor Voltage',
    'MOTOR_FAULTS': 'Motor Faults',
    'MOTOR_ESTIMATOR': 'Motor Estimator',
    'MOTOR_PHASE_CURRENT': 'Motor Phase Current',
  };

  static final List<CanDictionaryEntry> entries =
      List<CanDictionaryEntry>.unmodifiable(
        CanDatabase.messages.map(_entryFor).toList(growable: false),
      );

  static CanDictionaryEntry _entryFor(CanMessageDefinition message) {
    final senderText = message.senders.join(', ');
    final receiverText = message.receivers.join(', ');
    final direction = receiverText.isEmpty
        ? senderText
        : '$senderText -> $receiverText';
    final signalNames = message.signals.map((signal) => signal.name).join(', ');

    return CanDictionaryEntry(
      canId: message.canId,
      key: message.name,
      label: _labels[message.name] ?? message.name,
      expectedDlc: message.length,
      cycleTimeMs: message.cycleTimeMs,
      direction: direction,
      decodeNotes: message.comment ?? 'Signals: $signalNames',
    );
  }
}
