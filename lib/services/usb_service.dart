import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:telemetry_dashboard/services/mqtt_service.dart';
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

  String _lineBuffer = "";
  final RegExp _candumpRegex = RegExp(r'can0\s+([0-9a-fA-F]+)#([0-9a-fA-F]*)');

  // ESP32-C3 USB Serial/JTAG identifiers (CDC-ACM)
  static const int _espVid = 0x303A;  // Espressif VID
  static const int _espPid = 0x1001;  // USB Serial/JTAG PID

  // For simulation history
  double _mockEnergyJ780 = 0.0;
  double _mockSpeedKmh = 0.0;
  double _mockDistanceKm = 0.0;
  double _mockMcTemp = 40.0;
  double _mockBattTemp = 35.0;

  final MqttService mqttService;

  UsbService(this.state, this.mqttService);

  void sendString(String data) {
    if (_port != null) {
      _port!.write(Uint8List.fromList(data.codeUnits));
    } else if (state.isSimulated) {
      debugPrint("SIMULATED TX: $data");
    }
  }

  void start() {
    _connect();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) {
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
    state.setConnectionState(false);
  }

  Future<void> _connect() async {
    List<UsbDevice> devices = [];
    try {
      devices = await UsbSerial.listDevices();
    } catch (e) {
      debugPrint("USB list error: $e");
    }
    
    if (devices.isEmpty) {
      if (state.enableSimulation) {
        _startMockSimulation();
      } else {
        _mockTimer?.cancel();
        _mockTimer = null;
        state.isSimulated = false;
      }
      return;
    }

    _mockTimer?.cancel();
    _mockTimer = null;

    UsbDevice espDevice = devices.firstWhere(
      (d) => d.vid == _espVid && d.pid == _espPid,
      orElse: () => devices.first, // Fallback to first device if no ESP32-C3 found
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

    _subscription = _port!.inputStream?.listen((Uint8List event) {
      _processBytes(event);
    }, onDone: () {
      _handleDisconnect();
    }, onError: (e) {
      _handleDisconnect();
    });
  }

  void _handleDisconnect() {
    _port?.close();
    _port = null;
    _subscription?.cancel();
    state.setConnectionState(false);
  }

  void _startMockSimulation() {
    if (_mockTimer != null) return;
    state.isSimulated = true;
    final startTime = DateTime.now().millisecondsSinceEpoch / 1000.0;
    
    _mockTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      double t = (DateTime.now().millisecondsSinceEpoch / 1000.0) - startTime;
      
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
      _parseCandumpLine("can0 110#${tLe}${fHex}000000"); // seq and raw_adc as 00

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

      // --- SEND SPEED/MOTION (0x500) ---
      int rawSpeed = (_mockSpeedKmh * 1000).toInt();
      int rawDist = (_mockDistanceKm * 1000).toInt();
      String sLe = _to32BitLeHex(rawSpeed);
      String dLe = _to32BitLeHex(rawDist);
      _parseCandumpLine("can0 500#$sLe$dLe");

      // 3. ELECTRICAL ENGINE
      double volts = 72.0 - (throttle * 0.04);
      double amps = braking ? -30.0 : throttle * 2.2; 
      
      // --- SEND POWER (0x310) ---
      int vRaw = (volts / 0.003125).toInt();
      int aRaw = (amps / 0.0024).toInt();
      String vLe = (vRaw & 0xFFFF).toRadixString(16).padLeft(4, '0').split('').reversed.join(''); // Simple flip helper
      // Using proper LE packing
      String pVle = (vRaw & 0xFF).toRadixString(16).padLeft(2, '0') + ((vRaw >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      String pAle = (aRaw & 0xFF).toRadixString(16).padLeft(2, '0') + ((aRaw >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      _parseCandumpLine("can0 310#$pVle$pAle");

      // --- SEND ENERGY (0x312) ---
      _mockEnergyJ780 += (volts * amps) * 0.1;
      int eRaw = (_mockEnergyJ780 / 0.00768).toInt();
      // Pack 40-bit Energy (5 bytes)
      String eLe = "";
      for(int i=0; i<5; i++) { eLe += ((eRaw >> (i*8)) & 0xFF).toRadixString(16).padLeft(2, '0'); }
      _parseCandumpLine("can0 312#$eLe");

      // 4. UI STATE UPDATES (Keep these for the phone screen)
      state.updateMotion(_mockSpeedKmh, _mockDistanceKm, (_mockDistanceKm / 4.0).floor() + 1);
      state.updateThermals(_mockMcTemp, _mockBattTemp);
    });
  }

  String _to32BitLeHex(int value) {
  Uint8List b = Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);
  return b.map((e) => e.toRadixString(16).padLeft(2, '0')).join('');
}

  void _processBytes(Uint8List newBytes) {
    String chunk = String.fromCharCodes(newBytes);
    _lineBuffer += chunk;
    int newlineIndex;
    while ((newlineIndex = _lineBuffer.indexOf('\n')) != -1) {
      String line = _lineBuffer.substring(0, newlineIndex).trim();
      _lineBuffer = _lineBuffer.substring(newlineIndex + 1);
      if (line.isNotEmpty) _parseCandumpLine(line);
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
        mqttService.publish("Throttle_Percent", pedal.throttlePercent);
        mqttService.publish("Brake_Active", pedal.isBrakePressed ? 1.0 : 0.0);
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
        mqttService.publish("Voltage$suffix", power.voltage);
        mqttService.publish("Current$suffix", power.current780); 
        break;
        
      case CanMsgID.pwrEnergy:
        final energy = EnergyPayload.fromBytes(payloadBytes);
        state.updateEnergy(energy);
        
        mqttService.publish("Joules_780", energy.joules780);
        mqttService.publish("Joules_740", energy.joules740);
        break;
        
      case CanMsgID.hallStat:
        final hall = HallPayload.fromBytes(payloadBytes);
        state.updateMotion(hall.speed, hall.totalDist, state.lapNumber);
        
        mqttService.publish("Speed_Kmh", hall.speed);
        mqttService.publish("Distance_Km", hall.totalDist);
        break;
    }
  }
}
