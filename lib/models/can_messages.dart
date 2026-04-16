import 'dart:typed_data';

// CAN IDs based on CanMessages.h
class CanMsgID {
  static const int pedal = 0x110;
  static const int auxCtrl = 0x210;
  static const int pwrMonitor780 = 0x310;
  static const int pwrMonitor740 = 0x311;
  static const int pwrEnergy = 0x312;
  static const int dashStat = 0x400;
  static const int hallStat = 0x500; // Reserved for the new HallPayload
  static const int gpsFix = 0x510;
  static const int gpsPosition = 0x511;
  static const int gpsMotion = 0x512;
}

class CanDictionaryEntry {
  final int canId;
  final String key;
  final String label;
  final int expectedDlc;
  final String direction;
  final String decodeNotes;

  const CanDictionaryEntry({
    required this.canId,
    required this.key,
    required this.label,
    required this.expectedDlc,
    required this.direction,
    required this.decodeNotes,
  });

  String get hexId =>
      '0x${canId.toRadixString(16).toUpperCase().padLeft(3, '0')}';
}

class CanDictionary {
  static const List<CanDictionaryEntry> entries = <CanDictionaryEntry>[
    CanDictionaryEntry(
      canId: CanMsgID.pedal,
      key: 'pedal',
      label: 'Pedal Input',
      expectedDlc: 6,
      direction: 'Vehicle -> App',
      decodeNotes: 'Filtered throttle and brake-active bit.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.auxCtrl,
      key: 'auxCtrl',
      label: 'Auxiliary Controls',
      expectedDlc: 1,
      direction: 'Vehicle <-> App',
      decodeNotes: 'Lighting/wiper/horn/hazard bitfield state.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.pwrMonitor780,
      key: 'pwrMonitor780',
      label: 'Power Monitor 780',
      expectedDlc: 4,
      direction: 'Vehicle -> App',
      decodeNotes: 'Main pack voltage with 780 current scaling.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.pwrMonitor740,
      key: 'pwrMonitor740',
      label: 'Power Monitor 740',
      expectedDlc: 4,
      direction: 'Vehicle -> App',
      decodeNotes: 'Main pack voltage with 740 current scaling.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.pwrEnergy,
      key: 'pwrEnergy',
      label: 'Energy Counter',
      expectedDlc: 5,
      direction: 'Vehicle -> App',
      decodeNotes: '40-bit cumulative joules counter.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.dashStat,
      key: 'dashStat',
      label: 'Dashboard Status',
      expectedDlc: 8,
      direction: 'Vehicle -> App',
      decodeNotes: 'Error count/code, strategy, MC/Batt temperatures.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.hallStat,
      key: 'hallStat',
      label: 'Hall Speed/Distance',
      expectedDlc: 8,
      direction: 'Vehicle -> App',
      decodeNotes: 'Speed and odometry in little-endian uint32.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.gpsFix,
      key: 'gpsFix',
      label: 'External GPS Fix',
      expectedDlc: 2,
      direction: 'Vehicle -> App',
      decodeNotes: 'Satellite count and lock flags.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.gpsPosition,
      key: 'gpsPosition',
      label: 'External GPS Position',
      expectedDlc: 8,
      direction: 'Vehicle -> App',
      decodeNotes: 'Latitude/longitude E7 signed int32 pair.',
    ),
    CanDictionaryEntry(
      canId: CanMsgID.gpsMotion,
      key: 'gpsMotion',
      label: 'External GPS Motion',
      expectedDlc: 4,
      direction: 'Vehicle -> App',
      decodeNotes: 'Speed cm/s and heading centi-degrees.',
    ),
  ];
}

class PedalPayload {
  final double throttlePercent;
  final bool isBrakePressed;

  PedalPayload({required this.throttlePercent, required this.isBrakePressed});

  factory PedalPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 6)
      return PedalPayload(throttlePercent: 0, isBrakePressed: false);

    final bd = ByteData.sublistView(bytes);
    final filteredThrottle = bd.getUint16(0, Endian.little);
    final flags = bytes[2];

    // (filtered_throttle & 0x7FFF) * (100.0f / 32767.0f)
    final throttle = (filteredThrottle & 0x7FFF) * (100.0 / 32767.0);
    // brake_active is bit 2 (0x04)
    final brake = (flags & 0x04) != 0;

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
      return AuxControlPayload(
        leftTurn: false,
        rightTurn: false,
        brakeLight: false,
        headlights: false,
        hazards: false,
        horn: false,
        wipers: false,
      );
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
  final double voltage; // V
  final double current780; // A
  final double current740; // A

  PowerPayload({
    required this.voltage,
    required this.current780,
    required this.current740,
  });

  factory PowerPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 4)
      return PowerPayload(voltage: 0, current780: 0, current740: 0);

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
    int rawVal =
        bytes[0] |
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

class HallPayload {
  final double speed;
  final double totalDist;

  HallPayload({required this.speed, required this.totalDist});

  factory HallPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 8) return HallPayload(speed: 0, totalDist: 0);
    final bd = ByteData.sublistView(bytes);

    final rawSpeed = bd.getUint32(0, Endian.little);
    final rawDist = bd.getUint32(4, Endian.little);

    return HallPayload(speed: rawSpeed / 1000.0, totalDist: rawDist / 1000.0);
  }
}

class DashStatusPayload {
  final int errorCount;
  final String lastErrorCode;
  final String strategy;
  final double mcTempC;
  final double battTempC;

  DashStatusPayload({
    required this.errorCount,
    required this.lastErrorCode,
    required this.strategy,
    required this.mcTempC,
    required this.battTempC,
  });

  factory DashStatusPayload.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      return DashStatusPayload(
        errorCount: 0,
        lastErrorCode: 'NONE',
        strategy: 'PACE',
        mcTempC: 0,
        battTempC: 0,
      );
    }

    final errorCount = bytes[0];
    final rawErrorCode = bytes.length > 1 ? bytes[1] : 0;
    final strategyCode = bytes.length > 2 ? bytes[2] : 0;

    double mcTempC = bytes.length > 4 ? bytes[4].toDouble() : 0;
    double battTempC = bytes.length > 5 ? bytes[5].toDouble() : 0;

    if (bytes.length >= 8) {
      final bd = ByteData.sublistView(bytes);
      mcTempC = bd.getUint16(4, Endian.little) / 10.0;
      battTempC = bd.getUint16(6, Endian.little) / 10.0;
    }

    return DashStatusPayload(
      errorCount: errorCount,
      lastErrorCode: _decodeErrorCode(rawErrorCode),
      strategy: _decodeStrategy(strategyCode),
      mcTempC: mcTempC,
      battTempC: battTempC,
    );
  }

  static String _decodeErrorCode(int raw) {
    if (raw <= 0) {
      return 'NONE';
    }
    return '0x${raw.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  }

  static String _decodeStrategy(int raw) {
    switch (raw) {
      case 1:
        return 'ATTACK';
      case 2:
        return 'REGEN';
      case 3:
        return 'COAST';
      default:
        return 'PACE';
    }
  }
}

class ExternalGpsFixPayload {
  final int satellites;
  final bool isLocked;

  ExternalGpsFixPayload({required this.satellites, required this.isLocked});

  factory ExternalGpsFixPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 2) {
      return ExternalGpsFixPayload(satellites: 0, isLocked: false);
    }

    return ExternalGpsFixPayload(
      satellites: bytes[0],
      isLocked: (bytes[1] & 0x01) != 0,
    );
  }
}

class ExternalGpsPositionPayload {
  final double latitude;
  final double longitude;

  ExternalGpsPositionPayload({required this.latitude, required this.longitude});

  factory ExternalGpsPositionPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      return ExternalGpsPositionPayload(latitude: 0, longitude: 0);
    }

    final bd = ByteData.sublistView(bytes);
    final rawLat = bd.getInt32(0, Endian.little);
    final rawLon = bd.getInt32(4, Endian.little);

    return ExternalGpsPositionPayload(
      latitude: rawLat / 10000000.0,
      longitude: rawLon / 10000000.0,
    );
  }
}

class ExternalGpsMotionPayload {
  final double speedKmh;
  final double headingDeg;

  ExternalGpsMotionPayload({required this.speedKmh, required this.headingDeg});

  factory ExternalGpsMotionPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < 4) {
      return ExternalGpsMotionPayload(speedKmh: 0, headingDeg: 0);
    }

    final bd = ByteData.sublistView(bytes);
    final speedCmPerS = bd.getUint16(0, Endian.little);
    final headingCentiDeg = bd.getUint16(2, Endian.little);

    return ExternalGpsMotionPayload(
      speedKmh: speedCmPerS * 0.036,
      headingDeg: headingCentiDeg / 100.0,
    );
  }
}
