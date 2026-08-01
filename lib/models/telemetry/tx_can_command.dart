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
}
