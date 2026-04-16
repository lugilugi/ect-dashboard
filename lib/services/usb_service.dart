import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:telemetry_dashboard/services/mqtt_service.dart';
import 'package:telemetry_dashboard/services/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/can_tx_service.dart';
import 'package:telemetry_dashboard/services/local_spool_service.dart';
import 'package:usb_serial/transaction.dart';
import 'package:usb_serial/usb_serial.dart';
import '../providers/dashboard_state.dart';
import '../models/can_messages.dart';

class UsbService {
  final DashboardState state;
  UsbPort? _port;
  StreamSubscription<Uint8List>? _subscription;
  Transaction<Uint8List>? _transaction;
  Timer? _reconnectTimer;
  Timer? _mockTimer;
  bool _usbPluginUnavailable = false;
  bool _reportedUsbPluginUnavailable = false;

  String _lineBuffer = "";
  final RegExp _candumpRegex = RegExp(r'can0\s+([0-9a-fA-F]+)#([0-9a-fA-F]*)');

  // ESP32-C3 USB Serial/JTAG identifiers (CDC-ACM)
  static const int _espVid = 0x303A; // Espressif VID
  static const int _espPid = 0x1001; // USB Serial/JTAG PID

  // For simulation history
  double _mockEnergyJ780 = 0.0;
  double _mockSpeedKmh = 0.0;
  double _mockDistanceKm = 0.0;
  double _mockMcTemp = 40.0;
  final double _mockBattTemp = 35.0;
  double _mockLatDeg = 14.5660;
  double _mockLonDeg = 120.9920;
  double _mockHeadingDeg = 0.0;

  int _externalGpsSatellites = 0;
  bool _externalGpsLocked = false;
  double? _externalGpsLat;
  double? _externalGpsLon;
  double? _externalGpsSpeedKmh;
  double? _externalGpsHeadingDeg;

  final MqttService mqttService;
  final GpsSourceManager gpsSourceManager;
  final CanTxService? canTxService;
  final LocalSpoolService? localSpoolService;

  UsbService(
    this.state,
    this.mqttService,
    this.gpsSourceManager, [
    this.canTxService,
    this.localSpoolService,
  ]);

  void sendString(String data) {
    if (_port != null) {
      _port!.write(Uint8List.fromList(data.codeUnits));
    } else if (state.isSimulated) {
      debugPrint("SIMULATED TX: $data");
    }
  }

  void setSimulationEnabled(bool enabled) {
    if (enabled) {
      _subscription?.cancel();
      _subscription = null;
      _port?.close();
      _port = null;
      state.setConnectionState(false);
      _startMockSimulation();
      return;
    }

    _mockTimer?.cancel();
    _mockTimer = null;
    state.setSimulatedState(false);
    if (_port == null && !_usbPluginUnavailable) {
      unawaited(_connect());
    }
  }

  void start() {
    if (_usbPluginUnavailable) {
      if (state.enableSimulation) {
        _startMockSimulation();
      }
      return;
    }

    _connect();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_usbPluginUnavailable) {
        return;
      }
      if (_port == null && _mockTimer == null) {
        _connect();
      }
    });
  }

  void stop() {
    _reconnectTimer?.cancel();
    _mockTimer?.cancel();
    _subscription?.cancel();
    _transaction?.dispose();
    _port?.close();
    _port = null;
    state.setSimulatedState(false);
    state.setConnectionState(false);
  }

  Future<void> _connect() async {
    if (state.enableSimulation) {
      _startMockSimulation();
      state.setConnectionState(false);
      return;
    }

    if (_usbPluginUnavailable) {
      return;
    }

    List<UsbDevice> devices = [];
    try {
      devices = await UsbSerial.listDevices();
    } catch (e) {
      if (e is MissingPluginException) {
        _usbPluginUnavailable = true;
        if (!_reportedUsbPluginUnavailable) {
          debugPrint(
            'USB serial plugin unavailable on this platform. USB ingest disabled.',
          );
          _reportedUsbPluginUnavailable = true;
        }
        state.setConnectionState(false);
        if (state.enableSimulation) {
          _startMockSimulation();
        } else {
          state.setSimulatedState(false);
        }
        return;
      }

      debugPrint("USB list error: $e");
    }

    if (devices.isEmpty) {
      if (state.enableSimulation) {
        _startMockSimulation();
      } else {
        _mockTimer?.cancel();
        _mockTimer = null;
        state.setSimulatedState(false);
      }
      return;
    }

    _mockTimer?.cancel();
    _mockTimer = null;
    state.setSimulatedState(false);

    UsbDevice espDevice = devices.firstWhere(
      (d) => d.vid == _espVid && d.pid == _espPid,
      orElse: () =>
          devices.first, // Fallback to first device if no ESP32-C3 found
    );
    _port = await espDevice.create();

    if (_port == null) return;

    bool openResult = await _port!.open();
    if (!openResult) {
      _port = null;
      return;
    }

    await _port!.setDTR(true);
    await _port!.setRTS(true);
    // Note: For CDC-ACM (ESP32-C3 USB Serial/JTAG), baud rate is informational
    // only — data moves at USB speed. Set to match CAN_BAUD_RATE for consistency.
    await _port!.setPortParameters(
      500000,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    state.setConnectionState(true);

    _subscription = _port!.inputStream?.listen(
      (Uint8List event) {
        _processBytes(event);
      },
      onDone: () {
        _handleDisconnect();
      },
      onError: (e) {
        _handleDisconnect();
      },
    );
  }

  void _handleDisconnect() {
    _port?.close();
    _port = null;
    _subscription?.cancel();
    state.setSimulatedState(false);
    state.setConnectionState(false);
  }

  void _startMockSimulation() {
    if (_mockTimer != null) return;
    state.setSimulatedState(true);
    final startTime = DateTime.now().millisecondsSinceEpoch / 1000.0;

    _mockTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final t = (DateTime.now().millisecondsSinceEpoch / 1000.0) - startTime;

      // 1. INPUT LOGIC
      int throttle = ((sin(t / 2) + 1.2) * 40).toInt().clamp(0, 100);
      bool braking = (t % 8 > 6);
      if (braking) throttle = 0;

      // --- SEND PEDAL (0x110) ---
      int throttle15bit = ((throttle / 100.0) * 32767).toInt().clamp(0, 32767);
      int flags = braking ? 0x04 : 0x00;
      String tHex = throttle15bit.toRadixString(16).padLeft(4, '0');
      String tLe = tHex.substring(2, 4) + tHex.substring(0, 2);
      String fHex = flags.toRadixString(16).padLeft(2, '0');
      _emitSimulatedFrame(CanMsgID.pedal, '$tLe${fHex}000000');

      // 2. PHYSICS ENGINE
      if (braking) {
        _mockSpeedKmh -= 4.0;
        if (_mockSpeedKmh < 0) _mockSpeedKmh = 0;
        _mockMcTemp -= 0.1;
      } else {
        _mockSpeedKmh += (throttle / 100.0) * 1.5;
        if (_mockSpeedKmh > 160) _mockSpeedKmh = 160;
        _mockMcTemp += (throttle / 100.0) * 0.15;
      }
      _mockDistanceKm += _mockSpeedKmh * (0.1 / 3600.0);

      // Simulate a smooth heading/position track for external GPS frames.
      _mockHeadingDeg = (_mockHeadingDeg + 1.8) % 360.0;
      final stepKm = _mockSpeedKmh * (0.1 / 3600.0);
      final headingRad = _mockHeadingDeg * pi / 180.0;
      final latRad = _mockLatDeg * pi / 180.0;
      _mockLatDeg += (stepKm * cos(headingRad)) / 110.574;
      _mockLonDeg +=
          (stepKm * sin(headingRad)) / (111.320 * max(cos(latRad).abs(), 0.2));

      // --- SEND SPEED/MOTION (0x500) ---
      int rawSpeed = (_mockSpeedKmh * 1000).toInt();
      int rawDist = (_mockDistanceKm * 1000).toInt();
      String sLe = _to32BitLeHex(rawSpeed);
      String dLe = _to32BitLeHex(rawDist);
      _emitSimulatedFrame(CanMsgID.hallStat, '$sLe$dLe');

      // 3. ELECTRICAL ENGINE
      double volts = 72.0 - (throttle * 0.04);
      double amps = braking ? -30.0 : throttle * 2.2;

      // --- SEND POWER (0x310) ---
      int vRaw = (volts / 0.003125).toInt();
      int aRaw = (amps / 0.0024).toInt();
      // Using proper LE packing
      String pVle =
          (vRaw & 0xFF).toRadixString(16).padLeft(2, '0') +
          ((vRaw >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      String pAle =
          (aRaw & 0xFF).toRadixString(16).padLeft(2, '0') +
          ((aRaw >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      _emitSimulatedFrame(CanMsgID.pwrMonitor780, '$pVle$pAle');

      // --- SEND ENERGY (0x312) ---
      _mockEnergyJ780 += (volts * amps) * 0.1;
      int eRaw = (_mockEnergyJ780 / 0.00768).toInt();
      // Pack 40-bit Energy (5 bytes)
      String eLe = "";
      for (int i = 0; i < 5; i++) {
        eLe += ((eRaw >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0');
      }
      _emitSimulatedFrame(CanMsgID.pwrEnergy, eLe);

      // --- SEND DASH STATUS (0x400) ---
      final errorCount = braking && _mockSpeedKmh > 40.0 ? 1 : 0;
      final lastErrorCode = errorCount > 0 ? 0x2A : 0x00;
      final strategyCode = braking ? 2 : (throttle > 70 ? 1 : 0);
      final statusFlags = braking ? 0x01 : 0x00;
      final mcTempRaw = (_mockMcTemp * 10).round().clamp(0, 65535);
      final battTempRaw = (_mockBattTemp * 10).round().clamp(0, 65535);
      final dashPayload =
          '${errorCount.toRadixString(16).padLeft(2, '0')}'
          '${lastErrorCode.toRadixString(16).padLeft(2, '0')}'
          '${strategyCode.toRadixString(16).padLeft(2, '0')}'
          '${statusFlags.toRadixString(16).padLeft(2, '0')}'
          '${_to16BitLeHex(mcTempRaw)}'
          '${_to16BitLeHex(battTempRaw)}';
      _emitSimulatedFrame(CanMsgID.dashStat, dashPayload);

      // 4. EXTERNAL GPS FRAMES
      const int mockSatellites = 11;
      const int mockLockFlags = 0x01;
      _emitSimulatedFrame(
        CanMsgID.gpsFix,
        '${mockSatellites.toRadixString(16).padLeft(2, '0')}'
        '${mockLockFlags.toRadixString(16).padLeft(2, '0')}',
      );

      final gpsPositionBytes = Uint8List(8);
      final gpsPositionData = ByteData.sublistView(gpsPositionBytes);
      gpsPositionData.setInt32(
        0,
        (_mockLatDeg * 10000000).round(),
        Endian.little,
      );
      gpsPositionData.setInt32(
        4,
        (_mockLonDeg * 10000000).round(),
        Endian.little,
      );
      _emitSimulatedFrame(CanMsgID.gpsPosition, _bytesToHex(gpsPositionBytes));

      final gpsMotionBytes = Uint8List(4);
      final gpsMotionData = ByteData.sublistView(gpsMotionBytes);
      gpsMotionData.setUint16(
        0,
        (_mockSpeedKmh / 0.036).round().clamp(0, 65535),
        Endian.little,
      );
      gpsMotionData.setUint16(
        2,
        ((_mockHeadingDeg % 360.0) * 100).round().clamp(0, 35999),
        Endian.little,
      );
      _emitSimulatedFrame(CanMsgID.gpsMotion, _bytesToHex(gpsMotionBytes));
    });
  }

  String _to16BitLeHex(int value) {
    final b = Uint8List(2)
      ..buffer.asByteData().setUint16(0, value, Endian.little);
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
  }

  String _to32BitLeHex(int value) {
    Uint8List b = Uint8List(4)
      ..buffer.asByteData().setUint32(0, value, Endian.little);
    return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
  }

  void _emitSimulatedFrame(int id, String payloadHex) {
    final line = 'can0 ${id.toRadixString(16)}#$payloadHex';
    _ingestLineThroughUsbPipeline(line);
  }

  void _ingestLineThroughUsbPipeline(String line) {
    final framedLine = '$line\n';
    _processBytes(Uint8List.fromList(framedLine.codeUnits));
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
  }

  void _processBytes(Uint8List newBytes) {
    String chunk = String.fromCharCodes(newBytes);
    _lineBuffer += chunk;
    int newlineIndex;
    while ((newlineIndex = _lineBuffer.indexOf('\n')) != -1) {
      String line = _lineBuffer.substring(0, newlineIndex).trim();
      _lineBuffer = _lineBuffer.substring(newlineIndex + 1);
      if (line.isNotEmpty) {
        canTxService?.handleIncomingLine(line);
        _parseCandumpLine(line);
      }
    }
  }

  void _parseCandumpLine(String line) {
    final match = _candumpRegex.firstMatch(line);
    if (match != null) {
      final idStr = match.group(1);
      final dataStr = match.group(2) ?? '';
      if (idStr != null) {
        try {
          final id = int.parse(idStr, radix: 16);
          state.updateRawCan(id, dataStr); // Log raw hex for engineer screen
          final spool = localSpoolService;
          if (spool != null) {
            final sessionId = state.sessionId.isEmpty
                ? 'pending-session'
                : state.sessionId;
            unawaited(
              spool.enqueueRawFrame(
                sessionId: sessionId,
                tsSessionMs: state.sessionTimeSeconds * 1000,
                canId: id,
                payloadHex: dataStr,
                source: state.isSimulated ? 'simulation' : 'usb',
              ),
            );
          }
          final payloadBytes = _hexToBytes(dataStr);
          _dispatchPayload(id, payloadBytes);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  Uint8List _hexToBytes(String hexStr) {
    final bytes = <int>[];
    for (int i = 0; i < hexStr.length; i += 2) {
      if (i + 1 < hexStr.length) {
        bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
      }
    }
    return Uint8List.fromList(bytes);
  }

  void _dispatchPayload(int id, Uint8List payloadBytes) {
    switch (id) {
      case CanMsgID.pedal:
        final pedal = PedalPayload.fromBytes(payloadBytes);
        state.updatePedal(pedal);

        // Instantly publish to the cloud!
        mqttService.publish(
          "Throttle_Percent",
          pedal.throttlePercent,
          unit: "%",
          canId: id,
        );
        mqttService.publish(
          "Brake_Active",
          pedal.isBrakePressed ? 1.0 : 0.0,
          unit: "bool",
          canId: id,
        );
        break;

      case CanMsgID.auxCtrl:
        state.updateAux(AuxControlPayload.fromBytes(payloadBytes));
        break;

      case CanMsgID.pwrMonitor780:
      case CanMsgID.pwrMonitor740:
        final power = PowerPayload.fromBytes(payloadBytes);
        state.updatePower(power, id);

        // We separate 780 and 740 metrics for Grafana
        String suffix = (id == CanMsgID.pwrMonitor780) ? "_780" : "_740";
        mqttService.publish(
          "Voltage$suffix",
          power.voltage,
          unit: "V",
          canId: id,
        );
        mqttService.publish(
          "Current$suffix",
          power.current780,
          unit: "A",
          canId: id,
        );
        break;

      case CanMsgID.pwrEnergy:
        final energy = EnergyPayload.fromBytes(payloadBytes);
        state.updateEnergy(energy);

        mqttService.publish(
          "Joules_780",
          energy.joules780,
          unit: "J",
          canId: id,
        );
        mqttService.publish(
          "Joules_740",
          energy.joules740,
          unit: "J",
          canId: id,
        );
        break;

      case CanMsgID.dashStat:
        final dashStatus = DashStatusPayload.fromBytes(payloadBytes);
        state.updateDashStatus(dashStatus);

        mqttService.publish(
          'Error_Count',
          dashStatus.errorCount.toDouble(),
          unit: 'count',
          canId: id,
        );
        mqttService.publish(
          'MC_Temp_C',
          dashStatus.mcTempC,
          unit: 'C',
          canId: id,
        );
        mqttService.publish(
          'Batt_Temp_C',
          dashStatus.battTempC,
          unit: 'C',
          canId: id,
        );
        break;

      case CanMsgID.hallStat:
        final hall = HallPayload.fromBytes(payloadBytes);
        state.updateMotion(hall.speed, hall.totalDist, state.lapNumber);

        mqttService.publish("Speed_Kmh", hall.speed, unit: "km/h", canId: id);
        mqttService.publish(
          "Distance_Km",
          hall.totalDist,
          unit: "km",
          canId: id,
        );
        break;

      case CanMsgID.gpsFix:
        final fix = ExternalGpsFixPayload.fromBytes(payloadBytes);
        _externalGpsSatellites = fix.satellites;
        _externalGpsLocked = fix.isLocked;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample();

        mqttService.publish(
          'GPS_Satellites',
          fix.satellites.toDouble(),
          source: 'external_gps',
          unit: 'count',
          canId: id,
        );
        mqttService.publish(
          'GPS_Locked',
          fix.isLocked ? 1.0 : 0.0,
          source: 'external_gps',
          unit: 'bool',
          canId: id,
        );
        break;

      case CanMsgID.gpsPosition:
        final position = ExternalGpsPositionPayload.fromBytes(payloadBytes);
        _externalGpsLat = position.latitude;
        _externalGpsLon = position.longitude;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample();

        mqttService.publish(
          'GPS_Latitude_Deg',
          position.latitude,
          source: 'external_gps',
          unit: 'deg',
          canId: id,
        );
        mqttService.publish(
          'GPS_Longitude_Deg',
          position.longitude,
          source: 'external_gps',
          unit: 'deg',
          canId: id,
        );
        break;

      case CanMsgID.gpsMotion:
        final motion = ExternalGpsMotionPayload.fromBytes(payloadBytes);
        _externalGpsSpeedKmh = motion.speedKmh;
        _externalGpsHeadingDeg = motion.headingDeg;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample();

        mqttService.publish(
          'GPS_Speed_Kmh',
          motion.speedKmh,
          source: 'external_gps',
          unit: 'km/h',
          canId: id,
        );
        mqttService.publish(
          'GPS_Heading_Deg',
          motion.headingDeg,
          source: 'external_gps',
          unit: 'deg',
          canId: id,
        );
        break;
    }
  }

  void _tryEmitExternalGpsSample() {
    final lat = _externalGpsLat;
    final lon = _externalGpsLon;
    final speed = _externalGpsSpeedKmh;
    final heading = _externalGpsHeadingDeg;

    if (lat == null || lon == null || speed == null || heading == null) {
      return;
    }

    gpsSourceManager.ingestExternalSample(
      satellites: _externalGpsSatellites,
      locked: _externalGpsLocked,
      lat: lat,
      lon: lon,
      headingDeg: heading,
      speedKmh: speed,
      timestampUtc: DateTime.now().toUtc(),
    );
  }
}
