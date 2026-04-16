enum CanTxSafetyClass {
  emergency,
  operational,
  maintenance,
}

class TxCanCommand {
  final String commandKey;
  final List<int> args;
  final int? targetCanId;
  final int issuedAtMsUtc;
  final String source;
  final CanTxSafetyClass safetyTag;

  const TxCanCommand({
    required this.commandKey,
    this.args = const <int>[],
    required this.targetCanId,
    required this.issuedAtMsUtc,
    required this.source,
    required this.safetyTag,
  });

  Map<String, dynamic> toJson() {
    return {
      'command_key': commandKey,
      'args': args,
      'target_can_id': targetCanId,
      'issued_at_ms_utc': issuedAtMsUtc,
      'source': source,
      'safety_tag': safetyTag.name,
    };
  }

  factory TxCanCommand.fromJson(Map<String, dynamic> json) {
    return TxCanCommand(
      commandKey: json['command_key'] as String,
      args: (json['args'] as List<dynamic>).map((e) => (e as num).toInt()).toList(),
      targetCanId: (json['target_can_id'] as num?)?.toInt(),
      issuedAtMsUtc: (json['issued_at_ms_utc'] as num).toInt(),
      source: json['source'] as String,
      safetyTag: CanTxSafetyClass.values.firstWhere(
        (e) => e.name == json['safety_tag'],
        orElse: () => CanTxSafetyClass.operational,
      ),
    );
  }
}
