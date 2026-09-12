import 'dart:typed_data';

export 'generated/can_database.g.dart';

import 'generated/can_database.g.dart';

/// Decodes one validated classical-CAN payload using the generated DBC
/// implementation. Unknown IDs are ignored; known IDs with the wrong DLC
/// throw [CanDecodeException].
DecodedCanMessage? decodeCanFrame(int canId, Uint8List payload) {
  return CanDatabase.decode(canId, payload);
}
