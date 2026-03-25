import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
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

  UsbService(this.state);

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
      
      int throttle = ((sin(t / 2) + 1.2) * 40).toInt().clamp(0, 100); 
      bool braking = (t % 8 > 6);
      if (braking) { throttle = 0; }

      // Build proper 6-byte PedalPayload: [filtered_throttle:u16LE] [flags:u8] [seq:u8] [raw_adc:u16LE]
      int throttle15bit = ((throttle / 100.0) * 32767).toInt().clamp(0, 32767);
      int flags = braking ? 0x04 : 0x00; // bit 2 = brake_active
      int seq = (t * 10).toInt() & 0xFF;
      String tLo = (throttle15bit & 0xFF).toRadixString(16).padLeft(2, '0');
      String tHi = ((throttle15bit >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      String flagsHex = flags.toRadixString(16).padLeft(2, '0');
      String seqHex = seq.toRadixString(16).padLeft(2, '0');
      String adcLo = tLo; // raw_adc mirrors filtered for sim
      String adcHi = tHi;
      _parseCandumpLine("can0 110#$tLo$tHi$flagsHex$seqHex$adcLo$adcHi");

      if (braking) {
        state.updateStrategy("REGEN");
      } else if (throttle == 0) {
        state.updateStrategy("COAST");
      } else if (throttle > 80) {
        state.updateStrategy("BURN");
      } else {
        state.updateStrategy("PACE");
      }

      if (braking) {
        _mockSpeedKmh -= 4.0;
        if (_mockSpeedKmh < 0) _mockSpeedKmh = 0;
        _mockMcTemp -= 0.1;
        _mockBattTemp += 0.05; // Regen heats battery
      } else {
        _mockSpeedKmh += (throttle / 100.0) * 1.5; 
        if (_mockSpeedKmh > 160) _mockSpeedKmh = 160;
        _mockMcTemp += (throttle / 100.0) * 0.15;
        _mockBattTemp += (throttle / 100.0) * 0.02;
      }
      
      if (_mockMcTemp > 90.0) _mockMcTemp -= 0.5; 
      if (_mockBattTemp > 60.0) _mockBattTemp -= 0.1;

      // Random error generation
      if (t.toInt() % 45 == 0 && t > 10) {
        state.updateErrorCode("ERR 0x${(t.toInt()%255).toRadixString(16).toUpperCase()}");
      } else {
        state.updateErrorCode("OK");
      }
      
      _mockDistanceKm += _mockSpeedKmh * (0.1 / 3600.0);
      int lap = (_mockDistanceKm / 4.0).floor() + 1;
      
      state.updateMotion(_mockSpeedKmh, _mockDistanceKm, lap);
      state.updateThermals(_mockMcTemp, _mockBattTemp);

      // Engineer mock parameters
      List<double> cells = List.generate(24, (index) => 3.8 + (sin((t + index) * 2) * 0.05));
      double bus12 = 12.4 - (throttle * 0.01);
      state.updateEngineerMock(cells, bus12, t > 3 ? 8 : 0, t > 3);

      // Power
      double volts = 72.0 - (throttle * 0.04);
      double amps = braking ? -30.0 : throttle * 2.2; 
      int voltsRaw = (volts / 0.003125).toInt();
      int ampsRaw = (amps / 0.0024).toInt();
      
      String vHex = voltsRaw.toRadixString(16).padLeft(4, '0');
      String vLe = vHex.substring(2, 4) + vHex.substring(0, 2);
      
      String aHex = (ampsRaw & 0xFFFF).toRadixString(16).padLeft(4, '0');
      String aLe = aHex.substring(2, 4) + aHex.substring(0, 2);
      
      _parseCandumpLine("can0 310#$vLe$aLe");

      _mockEnergyJ780 += (volts * amps) * 0.1;
      state.energyJ780 = _mockEnergyJ780;
      state.energyJ740 = _mockEnergyJ780 * 0.05; 

      // Aux (0x210)
      int leftTurn = ((t * 2).toInt() % 2 == 0) ? 1 : 0;
      int wipersOn = ((t * 4).toInt() % 8 < 2) ? 1 : 0; 
      int auxRaw = leftTurn | 0x08 | (wipersOn << 6); 
      _parseCandumpLine("can0 210#${auxRaw.toRadixString(16).padLeft(2, '0')}");
    });
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
        state.updatePedal(PedalPayload.fromBytes(payloadBytes));
        break;
      case CanMsgID.auxCtrl:
        state.updateAux(AuxControlPayload.fromBytes(payloadBytes));
        break;
      case CanMsgID.pwrMonitor780:
      case CanMsgID.pwrMonitor740:
        state.updatePower(PowerPayload.fromBytes(payloadBytes), id);
        break;
      case CanMsgID.pwrEnergy:
        state.updateEnergy(EnergyPayload.fromBytes(payloadBytes));
        break;
      case CanMsgID.hallStat:
        final hall = HallPayload.fromBytes(payloadBytes);
        state.updateMotion(hall.speed, hall.totalDist, state.lapNumber); // Preserve current lap
        break;
    }
  }
}
