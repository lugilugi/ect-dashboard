import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/ingest/usb_debug_log.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/repositories/can_ingest_repository.dart';
import 'package:usb_serial/transaction.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/models/telemetry/can_messages.dart';
import 'package:telemetry_dashboard/models/telemetry/can_signal_registry.dart';

/// A selectable USB ingest endpoint: Android usb_serial device (id =
/// deviceName) or desktop serial port name (id = port name like COM5).
class UsbPortOption {
  final String id;
  final String label;

  const UsbPortOption({required this.id, required this.label});
}

class UsbService {
  final DashboardState state;
  final UsbDebugLogStore debugLog = UsbDebugLogStore();
  UsbPort? _port;
  StreamSubscription<Uint8List>? _subscription;
  StreamSubscription<CanFrameMessage>? _canFrameSubscription;
  StreamSubscription<CanParseError>? _canParseErrorSubscription;
  Transaction<Uint8List>? _transaction;
  Timer? _reconnectTimer;
  Timer? _mockTimer;
  Timer? _statsTimer;
  bool _usbPluginUnavailable = false;
  bool _reportedUsbPluginUnavailable = false;
  bool _ingestRepositoryAttached = false;

  // Desktop serial (Windows/macOS/Linux) fallback when usb_serial is
  // unavailable. Configured with --dart-define=DESKTOP_SERIAL_PORT=COM5 to
  // pin a specific port; without it the first usable port is auto-detected
  // (native USB CDC on /dev/ttyACM* is preferred, then /dev/ttyUSB*
  // bridges, then anything else). Baud is informational for ESP32-C3
  // CDC-ACM (USB Serial/JTAG) but matters for classic UART bridges like
  // the CP2102/CH340 found on ESP32 WROOM dev boards.
  static const String defaultDesktopSerialPort = String.fromEnvironment(
    'DESKTOP_SERIAL_PORT',
    defaultValue: 'COM3',
  );
  static const bool hasExplicitDesktopSerialPort =
      bool.hasEnvironment('DESKTOP_SERIAL_PORT');

  SerialPort? _desktopPort;
  StreamSubscription<Uint8List>? _desktopSubscription;

  static const int maxLineBufferBytes = 64 * 1024;
  static const int maxLineBytes = 8 * 1024;
  String _lineBuffer = "";
  final RegExp _candumpRegex = RegExp(r'can0\s+([0-9a-fA-F]+)#([0-9a-fA-F]*)');

  // ESP32 over USB arrives either as native Espressif CDC (ESP32-C3/S3 USB
  // Serial/JTAG, VID 0x303A) or through the USB-UART bridge chip soldered
  // onto classic ESP32 WROOM dev boards: Silicon Labs CP210x (0x10C4),
  // WCH CH340/CH341 (0x1A86), FTDI FT232 (0x0403). Vendor match keeps
  // auto-detection robust without knowing every bridge PID.
  static const Set<int> _preferredVendorIds = {
    0x303A, // Espressif native USB
    0x10C4, // Silicon Labs CP210x
    0x1A86, // WCH CH340/CH341
    0x0403, // FTDI FT232
  };

  // RX accounting for the periodic stats log entry.
  int _rxBytesTotal = 0;
  int _rxBytesLogged = 0;
  int _rxLinesTotal = 0;
  int _rxLinesLogged = 0;

  // Dedupes repeated connect failures so the in-app log is not flooded by
  // the 3-second reconnect timer.
  final Map<String, DateTime> _lastThrottledLogAt = {};

  void _logThrottled(
    String key,
    String message, {
    Duration minInterval = const Duration(seconds: 30),
  }) {
    final now = DateTime.now();
    final last = _lastThrottledLogAt[key];
    if (last != null && now.difference(last) < minInterval) {
      return;
    }
    _lastThrottledLogAt[key] = now;
    debugLog.warn(message);
  }

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
  final CanIngestRepository? canIngestRepository;

  UsbService(
    this.state,
    this.mqttService,
    this.gpsSourceManager, [
    this.canTxService,
    this.localSpoolService,
    this.canIngestRepository,
  ]);

  void sendString(String data) {
    final bytes = Uint8List.fromList(data.codeUnits);
    if (_port != null) {
      _port!.write(bytes);
      debugLog.info('TX ${bytes.length} B: ${_trimForLog(data)}');
    } else if (_desktopPort != null) {
      _desktopPort!.write(bytes);
      debugLog.info('TX ${bytes.length} B: ${_trimForLog(data)}');
    } else if (state.isSimulated) {
      debugPrint("SIMULATED TX: $data");
    }
  }

  void _stopMockSimulation() {
    if (_mockTimer == null && !state.isSimulated) {
      return;
    }
    _mockTimer?.cancel();
    _mockTimer = null;
    state.setSimulatedState(false);
    state.resetTelemetry();
  }

  void setSimulationEnabled(bool enabled) {
    if (enabled) {
      _subscription?.cancel();
      _subscription = null;
      _port?.close();
      _port = null;
      state.setConnectionState(false);
      debugLog.info('Simulation mode enabled (USB ingest paused)');
      _startMockSimulation();
      return;
    }

    _stopMockSimulation();
    if (_port == null && _desktopPort == null) {
      unawaited(_connect());
    }
  }

  void start() {
    debugLog.info('USB ingest started');
    if (canIngestRepository != null) {
      unawaited(_startIngestRepositoryBridge());
    }

    _connect();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_port == null && _desktopPort == null && _mockTimer == null) {
        _connect();
      }
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _logRxStats();
    });
  }

  void stop() {
    _reconnectTimer?.cancel();
    _mockTimer?.cancel();
    _statsTimer?.cancel();
    _subscription?.cancel();
    _desktopSubscription?.cancel();
    _desktopSubscription = null;
    _canFrameSubscription?.cancel();
    _canFrameSubscription = null;
    _canParseErrorSubscription?.cancel();
    _canParseErrorSubscription = null;
    _ingestRepositoryAttached = false;
    _transaction?.dispose();
    _port?.close();
    _port = null;
    _desktopPort?.close();
    _desktopPort = null;
    state.setSimulatedState(false);
    state.setConnectionState(false);
    debugLog.info('USB ingest stopped');
  }

  Future<void> _connect() async {
    if (state.enableSimulation) {
      _startMockSimulation();
      state.setConnectionState(false);
      return;
    }

    List<UsbDevice> devices = [];
    try {
      devices = await UsbSerial.listDevices();
    } catch (e) {
      if (e is MissingPluginException) {
        // usb_serial is Android-only; fall back to the desktop serial port
        // (Windows/macOS/Linux) so the laptop can ingest from the ESP32 too.
        _usbPluginUnavailable = true;
        if (!_reportedUsbPluginUnavailable) {
          debugLog.warn(
            'usb_serial plugin unavailable; using desktop serial fallback.',
          );
          _reportedUsbPluginUnavailable = true;
        }
        await _connectDesktopSerial();
        return;
      }

      _logThrottled('usb_list_error', 'USB device list error: $e');
      return;
    }

    if (devices.isEmpty) {
      if (_usbPluginUnavailable) {
        await _connectDesktopSerial();
      } else if (state.enableSimulation) {
        _startMockSimulation();
      } else {
        _stopMockSimulation();
        _logThrottled('no_usb_devices', 'No USB devices found; retrying...');
      }
      return;
    }

    _stopMockSimulation();

    try {
      // Prefer the user-selected device, then an Espressif device or a
      // WROOM USB-UART bridge (CP210x, CH340, FT232); fall back to the
      // first device otherwise.
      final selectedName = state.usbPortSelection;
      UsbDevice espDevice;
      if (selectedName.isNotEmpty) {
        espDevice = devices.firstWhere(
          (d) => d.deviceName == selectedName,
          orElse: () => devices.first,
        );
        if (espDevice.deviceName != selectedName) {
          _logThrottled(
            'usb_selected_missing',
            'Selected USB port $selectedName not found; '
            'falling back to ${_describeUsbDevice(espDevice)}',
          );
        }
      } else {
        espDevice = devices.firstWhere(
          (d) => _preferredVendorIds.contains(d.vid),
          orElse: () => devices.first,
        );
      }
      debugLog.info(
        'Found USB device: ${_describeUsbDevice(espDevice)}',
      );
      _port = await espDevice.create();

      if (_port == null) return;

      bool openResult = await _port!.open();
      if (!openResult) {
        _logThrottled(
          'usb_open_failed',
          'Failed to open USB device '
          '${espDevice.vid?.toRadixString(16)}:${espDevice.pid?.toRadixString(16)}',
        );
        _port = null;
        return;
      }

      await _port!.setDTR(true);
      await _port!.setRTS(true);
      // Note: For CDC-ACM (ESP32-C3 USB Serial/JTAG), baud rate is
      // informational only — data moves at USB speed. Set to match
      // CAN_BAUD_RATE for consistency.
      await _port!.setPortParameters(
        500000,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      state.setConnectionState(true);
      debugLog.info(
        'USB port open: ${espDevice.deviceName} '
        '(${espDevice.vid?.toRadixString(16)}:${espDevice.pid?.toRadixString(16)} '
        '${espDevice.productName ?? ''})',
      );

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
    } catch (e) {
      // e.g. the user denied the USB permission dialog — retry later via
      // the reconnect timer instead of surfacing an unhandled error.
      _logThrottled('usb_open_error', 'USB open failed: $e');
      await _port?.close();
      _port = null;
      state.setConnectionState(false);
    }
  }

  String _describeUsbDevice(UsbDevice device) {
    final vid = device.vid?.toRadixString(16).padLeft(4, '0') ?? '????';
    final pid = device.pid?.toRadixString(16).padLeft(4, '0') ?? '????';
    final name = device.productName ?? device.deviceName;
    return '$name (VID $vid PID $pid)';
  }

  /// Enumerates selectable USB endpoints for the current platform:
  /// Android usb_serial devices (or desktop serial ports when the plugin is
  /// unavailable), desktop ports otherwise.
  Future<List<UsbPortOption>> listPortOptions() async {
    if (!_usbPluginUnavailable) {
      try {
        final devices = await UsbSerial.listDevices();
        if (devices.isNotEmpty) {
          return [
            for (final device in devices)
              UsbPortOption(
                id: device.deviceName,
                label: '${_describeUsbDevice(device)} (${device.deviceName})',
              ),
          ];
        }
      } on MissingPluginException {
        _usbPluginUnavailable = true;
      } catch (e) {
        debugLog.warn('USB device enumeration failed: $e');
      }
    }

    List<String> ports = const [];
    try {
      ports = List<String>.from(SerialPort.availablePorts);
    } catch (e) {
      debugLog.warn('Desktop serial enumeration failed: $e');
    }
    return [
      for (final port in ports) UsbPortOption(id: port, label: port),
    ];
  }

  /// Reacts to a user port selection made in Config -> Connectivity (the
  /// state is already updated by DashboardState.updateUsbPortSelection):
  /// tears down the current connection and reconnects to the chosen port.
  void applyPortSelection(String portId) {
    final hadPort = _port != null || _desktopPort != null;
    final wasSimulated = state.isSimulated;
    _subscription?.cancel();
    _subscription = null;
    _desktopSubscription?.cancel();
    _desktopSubscription = null;
    _port?.close();
    _port = null;
    _desktopPort?.close();
    _desktopPort = null;
    state.setConnectionState(false);

    if (portId.isEmpty) {
      debugLog.info('USB port selection cleared; using auto-detection');
    } else {
      debugLog.info('USB port selection changed to $portId');
    }
    if (hadPort && !wasSimulated && !state.enableSimulation) {
      unawaited(_connect());
    }
  }

  /// Order of desktop serial ports to try. The user's Config selection wins,
  /// then an explicit --dart-define=DESKTOP_SERIAL_PORT=COM5, then
  /// auto-detection: native ESP32 CDC (/dev/ttyACM*), then classic UART
  /// bridges (/dev/ttyUSB*, e.g. CP2102/CH340 WROOM boards), then anything
  /// else (Windows COM ports, in enumeration order). Missing candidates are
  /// skipped so a stale selection degrades to auto-detection instead of
  /// blocking the reconnect loop.
  List<String> _candidateDesktopPorts() {
    List<String> available;
    try {
      available = List<String>.from(SerialPort.availablePorts);
    } catch (e) {
      debugLog.error('Desktop serial enumeration failed: $e');
      return <String>[];
    }

    if (available.isEmpty) {
      return <String>[];
    }

    final selected = state.usbPortSelection;
    final ordered = <String>[];
    if (selected.isNotEmpty && available.contains(selected)) {
      ordered.add(selected);
    }
    if (hasExplicitDesktopSerialPort &&
        defaultDesktopSerialPort != selected &&
        available.contains(defaultDesktopSerialPort)) {
      ordered.add(defaultDesktopSerialPort);
    }
    final nativeUsb = <String>[];
    final uartBridges = <String>[];
    final others = <String>[];
    for (final port in available) {
      if (port == selected || port == defaultDesktopSerialPort) {
        continue;
      }
      if (port.startsWith('/dev/ttyACM')) {
        nativeUsb.add(port);
      } else if (port.startsWith('/dev/ttyUSB')) {
        uartBridges.add(port);
      } else {
        others.add(port);
      }
    }
    ordered.addAll(nativeUsb);
    ordered.addAll(uartBridges);
    ordered.addAll(others);
    final seen = <String>{};
    return [
      for (final port in ordered)
        if (seen.add(port)) port,
    ];
  }

  Future<void> _connectDesktopSerial() async {
    if (_desktopPort != null) {
      return;
    }

    final candidates = _candidateDesktopPorts();
    if (candidates.isEmpty) {
      _logThrottled(
        'no_serial_ports',
        'No desktop serial ports available; retrying...',
      );
      return;
    }

    final explicit = hasExplicitDesktopSerialPort
        ? ' (explicit --dart-define)'
        : ' (auto-detected)';
    _logThrottled(
      'serial_try_ports',
      'Desktop serial: trying ${candidates.join(', ')}$explicit',
      minInterval: const Duration(minutes: 1),
    );

    for (final portName in candidates) {
      try {
        final port = SerialPort(portName);
        if (!port.openRead()) {
          debugLog.warn(
            'Failed to open serial port $portName: ${SerialPort.lastError}',
          );
          port.dispose();
          continue;
        }

        // For ESP32-C3 USB Serial/JTAG (CDC-ACM) the baud rate is
        // informational; for classic UART bridges it must match the
        // firmware (115200 typical).
        final config = port.config;
        config.baudRate = 115200;
        port.config = config;

        _desktopPort = port;
        state.setConnectionState(true);
        debugLog.info('Opened serial port $portName @ 115200 baud');

        _desktopSubscription = SerialPortReader(port).stream.listen(
          _processBytes,
          onDone: _handleDesktopDisconnect,
          onError: (Object e) {
            debugLog.error('Serial stream error on $portName: $e');
            _handleDesktopDisconnect();
          },
        );
        return;
      } catch (e) {
        debugLog.warn('Serial connect error on $portName: $e');
        _desktopPort?.close();
        _desktopPort = null;
      }
    }

    _logThrottled(
      'serial_all_failed',
      'All serial candidates failed; retrying...',
    );
  }

  void _handleDesktopDisconnect() {
    _desktopSubscription?.cancel();
    _desktopSubscription = null;
    _desktopPort?.close();
    _desktopPort = null;
    state.setConnectionState(false);
    debugLog.warn('Desktop serial port disconnected');
  }

  void _handleDisconnect() {
    _port?.close();
    _port = null;
    _subscription?.cancel();
    state.setSimulatedState(false);
    state.setConnectionState(false);
    debugLog.warn('USB device disconnected');
  }

  void _startMockSimulation() {
    if (_mockTimer != null) return;
    debugLog.info('Simulation mode active (mock CAN frames)');
    state.setSimulatedState(true);
    final startTime = DateTime.now().millisecondsSinceEpoch / 1000.0;

    _mockTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final t = (DateTime.now().millisecondsSinceEpoch / 1000.0) - startTime;

      // 1. INPUT LOGIC
      // The simulated vehicle drives even without a running session, matching
      // the real vehicle (which is driven to the grid before START): slow
      // drive-and-stop cycles keep telemetry flowing while the real standstill
      // start gate stays passable during each full stop. While a session is
      // logging, the full race physics run.
      final isLogging = state.isLogging;
      int throttle = ((sin(t / 2) + 1.2) * 40).toInt().clamp(0, 100);
      bool braking = (t % 8 > 6);
      if (braking) throttle = 0;
      if (!isLogging) {
        final cycleT = t % 12.0;
        if (cycleT < 6.0) {
          throttle = throttle.clamp(0, 15);
          braking = false;
        } else {
          throttle = 0;
          braking = true;
        }
      }

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

      // A stationary vehicle keeps its heading and position.
      if (_mockSpeedKmh > 0.5) {
        _mockHeadingDeg = (_mockHeadingDeg + 1.8) % 360.0;
        final stepKm = _mockSpeedKmh * (0.1 / 3600.0);
        final headingRad = _mockHeadingDeg * pi / 180.0;
        final latRad = _mockLatDeg * pi / 180.0;
        _mockLatDeg += (stepKm * cos(headingRad)) / 110.574;
        _mockLonDeg +=
            (stepKm * sin(headingRad)) / (111.320 * max(cos(latRad).abs(), 0.2));
      }

      // --- SEND SPEED/MOTION (0x500) ---
      int rawSpeed = (_mockSpeedKmh * 1000).toInt();
      int rawDist = (_mockDistanceKm * 1000).toInt();
      String sLe = _to32BitLeHex(rawSpeed);
      String dLe = _to32BitLeHex(rawDist);
      _emitSimulatedFrame(CanMsgID.hallStat, '$sLe$dLe');

      // 3. ELECTRICAL ENGINE
      double volts = 72.0 - (throttle * 0.04);
      // Regen only while actually decelerating from motion, not at standstill.
      final bool regening = braking && _mockSpeedKmh > 0.5;
      double amps = regening ? -30.0 : throttle * 2.2;

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
    _rxBytesTotal += newBytes.length;
    String chunk = String.fromCharCodes(newBytes);
    _lineBuffer += chunk;
    if (_lineBuffer.length > maxLineBufferBytes) {
      debugLog.warn(
        'Serial line buffer overflow; dropping oldest partial data '
        '(${_lineBuffer.length} bytes buffered).',
      );
      final keepFrom = _lineBuffer.lastIndexOf('\n') + 1;
      _lineBuffer = keepFrom > 0
          ? _lineBuffer.substring(keepFrom)
          : '';
    }
    int newlineIndex;
    while ((newlineIndex = _lineBuffer.indexOf('\n')) != -1) {
      String line = _lineBuffer.substring(0, newlineIndex).trim();
      _lineBuffer = _lineBuffer.substring(newlineIndex + 1);
      if (line.isEmpty) {
        continue;
      }
      if (line.length > maxLineBytes) {
        debugLog.warn('Dropping over-long serial line (${line.length} bytes).');
        continue;
      }
      {
        _rxLinesTotal += 1;
        canTxService?.handleIncomingLine(line);
        final repo = canIngestRepository;
        if (repo != null) {
          unawaited(repo.ingestLine(line, source: _resolveIngestSource()));
        } else {
          _parseCandumpLine(line);
        }
      }
    }
  }

  void _logRxStats() {
    final bytesDelta = _rxBytesTotal - _rxBytesLogged;
    final linesDelta = _rxLinesTotal - _rxLinesLogged;
    _rxBytesLogged = _rxBytesTotal;
    _rxLinesLogged = _rxLinesTotal;
    if (bytesDelta > 0 || linesDelta > 0) {
      debugLog.info(
        'RX +$bytesDelta B / +$linesDelta lines '
        '(totals $_rxBytesTotal B / $_rxLinesTotal lines)',
      );
    }
  }

  String _trimForLog(String data, {int maxChars = 120}) {
    if (data.length <= maxChars) {
      return data;
    }
    return '${data.substring(0, maxChars)}...';
  }

  Future<void> _startIngestRepositoryBridge() async {
    final repo = canIngestRepository;
    if (repo == null || _ingestRepositoryAttached) {
      return;
    }

    await repo.start();

    _canFrameSubscription = repo.frames.listen(
      _handleParsedCanFrame,
      onError: (Object e) {
        debugPrint('CAN ingest repository frame stream error: $e');
      },
    );

    _canParseErrorSubscription = repo.parseErrors.listen(
      (error) {
        debugLog.warn(
          'CAN parse error [${error.source}]: ${error.reason} '
          'line="${_trimForLog(error.line, maxChars: 80)}"',
        );
        debugPrint(
          'CAN parse error [${error.source}]: ${error.reason} line="${error.line}"',
        );
      },
      onError: (Object e) {
        debugPrint('CAN ingest repository parse error stream failure: $e');
      },
    );

    _ingestRepositoryAttached = true;
  }

  void _parseCandumpLine(String line) {
    final match = _candumpRegex.firstMatch(line);
    if (match != null) {
      final idStr = match.group(1);
      final dataStr = match.group(2) ?? '';
      if (idStr != null) {
        try {
          final id = int.parse(idStr, radix: 16);
          _handleParsedCanFrame(
            CanFrameMessage(
              canId: id,
              payloadHex: dataStr,
              source: _resolveIngestSource(),
              receivedAtUtc: DateTime.now().toUtc(),
            ),
          );
        } catch (e) {
          // ignore
        }
      }
    }
  }

  void _handleParsedCanFrame(CanFrameMessage frame) {
    state.updateRawCan(frame.canId, frame.payloadHex);

    final payloadBytes = _hexToBytes(frame.payloadHex);
    _dispatchPayload(frame.canId, payloadBytes);
  }

  String _resolveIngestSource() {
    return state.isSimulated ? 'simulation' : 'usb';
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
        _publishSignals(id, {
          "Throttle_Percent": pedal.throttlePercent,
          "Brake_Active": pedal.isBrakePressed ? 1.0 : 0.0,
        });
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
        _publishSignals(id, {
          "Voltage$suffix": power.voltage,
          "Current$suffix": power.current780,
        });
        break;

      case CanMsgID.pwrEnergy:
        final energy = EnergyPayload.fromBytes(payloadBytes);
        state.updateEnergy(energy);

        _publishSignals(id, {
          "Joules_780": energy.joules780,
          "Joules_740": energy.joules740,
        });
        break;

      case CanMsgID.dashStat:
        final dashStatus = DashStatusPayload.fromBytes(payloadBytes);
        state.updateDashStatus(dashStatus);

        _publishSignals(id, {
          'Error_Count': dashStatus.errorCount.toDouble(),
          'MC_Temp_C': dashStatus.mcTempC,
          'Batt_Temp_C': dashStatus.battTempC,
        });
        break;

      case CanMsgID.hallStat:
        final hall = HallPayload.fromBytes(payloadBytes);
        state.updateMotion(hall.speed, hall.totalDist, state.lapNumber);

        _publishSignals(id, {
          "Speed_Kmh": hall.speed,
          "Distance_Km": hall.totalDist,
        });
        break;

      case CanMsgID.gpsFix:
        final fix = ExternalGpsFixPayload.fromBytes(payloadBytes);
        _externalGpsSatellites = fix.satellites;
        _externalGpsLocked = fix.isLocked;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample();

        _publishSignals(id, {
          'GPS_Satellites': fix.satellites.toDouble(),
          'GPS_Locked': fix.isLocked ? 1.0 : 0.0,
          'GPS_Fallback_Active': 0.0,
          'GPS_Fallback_Period_Ms': state.gpsFallbackPeriodMs.toDouble(),
        });
        break;

      case CanMsgID.gpsPosition:
        final position = ExternalGpsPositionPayload.fromBytes(payloadBytes);
        _externalGpsLat = position.latitude;
        _externalGpsLon = position.longitude;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample();

        _publishSignals(id, {
          'GPS_Latitude_Deg': position.latitude,
          'GPS_Longitude_Deg': position.longitude,
        });
        break;

      case CanMsgID.gpsMotion:
        final motion = ExternalGpsMotionPayload.fromBytes(payloadBytes);
        _externalGpsSpeedKmh = motion.speedKmh;
        _externalGpsHeadingDeg = motion.headingDeg;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample();

        _publishSignals(id, {
          'GPS_Speed_Kmh': motion.speedKmh,
          'GPS_Heading_Deg': motion.headingDeg,
        });
        break;
    }
  }

  /// Publishes each signal defined in the [canSignalRegistry] for [canId].
  /// Add/remove signals by editing the registry (see can_signal_registry.dart).
  void _publishSignals(int canId, Map<String, double> values) {
    for (final entry in values.entries) {
      final spec = canSignalSpecByName(entry.key);
      if (spec == null) {
        continue;
      }
      mqttService.publish(
        spec.signalName,
        entry.value,
        source: spec.source,
        unit: spec.unit,
        canId: canId,
      );
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
