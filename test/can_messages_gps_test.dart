import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/can_messages.dart';

void main() {
  group('External GPS payload decoders', () {
    test('decodes GPS fix payload', () {
      final payload = ExternalGpsFixPayload.fromBytes(
        Uint8List.fromList(<int>[12, 0x01]),
      );

      expect(payload.satellites, 12);
      expect(payload.isLocked, isTrue);
    });

    test('decodes GPS position payload in E7 format', () {
      final bytes = Uint8List(8);
      final data = ByteData.sublistView(bytes);
      data.setInt32(0, 145661234, Endian.little);
      data.setInt32(4, 1209912345, Endian.little);

      final payload = ExternalGpsPositionPayload.fromBytes(bytes);

      expect(payload.latitude, closeTo(14.5661234, 0.0000001));
      expect(payload.longitude, closeTo(120.9912345, 0.0000001));
    });

    test('decodes GPS motion payload', () {
      final bytes = Uint8List(4);
      final data = ByteData.sublistView(bytes);
      data.setUint16(0, 1000, Endian.little); // 10 m/s
      data.setUint16(2, 1234, Endian.little); // 12.34 deg

      final payload = ExternalGpsMotionPayload.fromBytes(bytes);

      expect(payload.speedKmh, closeTo(36.0, 0.0001));
      expect(payload.headingDeg, closeTo(12.34, 0.0001));
    });
  });
}
