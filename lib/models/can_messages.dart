import 'dart:typed_data';

// CAN IDs based on CanMessages.h
class CanMsgID {
  static const int pedal = 0x110;
  static const int auxCtrl = 0x210;
  static const int pwrMonitor780 = 0x310;
  static const int pwrMonitor740 = 0x311;
  static const int pwrEnergy = 0x312;
  static const int dashStat = 0x400;
}

class PedalPayload {
  final double throttlePercent;
  final bool isBrakePressed;

  PedalPayload({required this.throttlePercent, required this.isBrakePressed});

  factory PedalPayload.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) return PedalPayload(throttlePercent: 0, isBrakePressed: false);
    final rawData = bytes[0];
    // throttle computation: (rawData >> 1) * (100/127) => ~0.7874
    final throttle = (rawData >> 1) * 0.7874;
    final brake = (rawData & 0x01) == 1;
    return PedalPayload(throttlePercent: throttle, isBrakePressed: brake);
  }
}

class AuxControlPayload {
  final bool leftTurn;
  final bool rightTurn;
  final bool brakeLight;
  final bool headlights;
  final bool hazards;
  final bool horn;
  final bool wipers;

  AuxControlPayload({
    required this.leftTurn,
    required this.rightTurn,
    required this.brakeLight,
    required this.headlights,
    required this.hazards,
    required this.horn,
    required this.wipers,
  });

  factory AuxControlPayload.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      return AuxControlPayload(leftTurn: false, rightTurn: false, brakeLight: false, headlights: false, hazards: false, horn: false, wipers: false);
    }
    final raw = bytes[0];
    return AuxControlPayload(
      leftTurn: (raw & 0x01) != 0,
      rightTurn: (raw & 0x02) != 0,
      brakeLight: (raw & 0x04) != 0,
      headlights: (raw & 0x08) != 0,
      hazards: (raw & 0x10) != 0,
      horn: (raw & 0x20) != 0,
      wipers: (raw & 0x40) != 0,
    );
  }
}

class PowerPayload {
  final double voltage;      // V
  final double current780;   // A
  final double current740;   // A

  PowerPayload({required this.voltage, required this.current780, required this.current740});

  factory PowerPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 4) return PowerPayload(voltage: 0, current780: 0, current740: 0);

    // Assuming little-endian packing of uint16_t and int16_t from ESP32
    final bd = ByteData.sublistView(bytes);
    final rawVolts = bd.getUint16(0, Endian.little);
    final rawAmps = bd.getInt16(2, Endian.little);

    const vScale = 0.003125;
    const iScale780 = 0.0024;
    const iScale740 = 0.0012;

    return PowerPayload(
      voltage: rawVolts * vScale,
      current780: rawAmps * iScale780,
      current740: rawAmps * iScale740,
    );
  }
}

class EnergyPayload {
  final double joules780;
  final double joules740;

  EnergyPayload({required this.joules780, required this.joules740});

  factory EnergyPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 5) return EnergyPayload(joules780: 0, joules740: 0);
    
    // Read 40 bits (5 bytes) little endian
    int rawVal = bytes[0] |
                (bytes[1] << 8) |
                (bytes[2] << 16) |
                (bytes[3] << 24) |
                (bytes[4] << 32);

    const eScale780 = 0.00768;
    const eScale740 = 0.00384;

    return EnergyPayload(
      joules780: rawVal * eScale780,
      joules740: rawVal * eScale740,
    );
  }
}
