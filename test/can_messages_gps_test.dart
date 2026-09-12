import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';

void main() {
  group('Generated CAN database decoders', () {
    test('contains the ECT2026 CAN V5 catalog', () {
      expect(CanDatabase.version, 'ECT2026_CAN_V5');
      expect(CanDatabase.messages, hasLength(16));
      expect(CanIds.vehicleMotion, 0x400);
      expect(CanIds.gpsStatus, 0x410);
      expect(CanIds.motorPhaseCurrent, 0x605);
    });

    test('decodes vehicle motion and applies DBC scaling', () {
      final bytes = Uint8List(8);
      final data = ByteData.sublistView(bytes);
      data.setUint16(0, 4237, Endian.little); // 42.37 km/h
      data.setUint32(2, 18342, Endian.little); // 1834.2 m
      bytes[6] = 1;
      bytes[7] = 51;

      final message = decodeCanFrame(CanIds.vehicleMotion, bytes)!;

      expect(message.messageName, 'VEHICLE_MOTION');
      expect(message.value('speed_kmh'), closeTo(42.37, 0.0001));
      expect(message.value('trip_distance_m'), closeTo(1834.2, 0.0001));
      expect(message.value('motion_valid'), 1.0);
      expect(message.value('seq_counter'), 51.0);
    });

    test('decodes GPS fix payload', () {
      final payload = decodeCanFrame(
        CanIds.gpsStatus,
        Uint8List.fromList(<int>[12, 0x0F, 7, 0]),
      )!;

      expect(payload.value('satellites'), 12.0);
      expect(payload.value('fix_valid'), 1.0);
      expect(payload.value('position_valid'), 1.0);
      expect(payload.value('motion_valid'), 1.0);
      expect(payload.value('seq_counter'), 7.0);
    });

    test('decodes GPS position payload in E7 format', () {
      final bytes = Uint8List(8);
      final data = ByteData.sublistView(bytes);
      data.setInt32(0, 145661234, Endian.little);
      data.setInt32(4, 1209912345, Endian.little);

      final payload = decodeCanFrame(CanIds.gpsPosition, bytes)!;

      expect(payload.value('latitude_deg'), closeTo(14.5661234, 0.0000001));
      expect(payload.value('longitude_deg'), closeTo(120.9912345, 0.0000001));
    });

    test('decodes GPS motion payload', () {
      final bytes = Uint8List(4);
      final data = ByteData.sublistView(bytes);
      data.setUint16(0, 1000, Endian.little); // 10.00 km/h
      data.setUint16(2, 1234, Endian.little); // 12.34 deg

      final payload = decodeCanFrame(CanIds.gpsMotion, bytes)!;

      expect(payload.value('gps_speed_kmh'), closeTo(10.0, 0.0001));
      expect(payload.value('heading_deg'), closeTo(12.34, 0.0001));
    });

    test('rejects a known frame with the wrong DLC', () {
      expect(
        () =>
            decodeCanFrame(CanIds.gpsStatus, Uint8List.fromList(<int>[12, 1])),
        throwsA(isA<CanDecodeException>()),
      );
    });
  });
}
