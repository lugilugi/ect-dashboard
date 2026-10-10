import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/ingest/ble_nus_transport.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/ingest/ingest_transport.dart';
import 'package:telemetry_dashboard/services/ingest/usb_debug_log.dart';
import 'package:telemetry_dashboard/services/ingest/usb_serial_transport.dart';
import 'package:telemetry_dashboard/repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/models/telemetry/can_bindings.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';

export 'package:telemetry_dashboard/services/ingest/ingest_transport.dart'
    show LinkMode, UsbPortOption;

/// Builds the transport for a link mode; injectable for tests.
typedef IngestTransportFactory =
    IngestTransport Function(
      LinkMode mode, {
      required IngestLinkLog debugLog,
      required void Function(Uint8List bytes) onBytes,
      required void Function(String reason) onDisconnected,
    });

/// Vehicle link service: owns the active transport (USB serial or BLE,
/// chosen by [DashboardState.linkMode]), the reconnect loop, simulation and
/// the shared line pipeline (framing, command acks, CAN decode). Every
/// transport feeds the same bytes into [_processBytes].
class UsbService {
  final DashboardState state;
  final UsbDebugLogStore debugLog = UsbDebugLogStore();
  late final IngestLinkLog _log = IngestLinkLog(debugLog);
  final IngestTransportFactory? _transportFactory;
  IngestTransport? _transport;
  StreamSubscription<CanFrameMessage>? _canFrameSubscription;
  StreamSubscription<CanParseError>? _canParseErrorSubscription;
  Timer? _reconnectTimer;
  Timer? _mockTimer;
  Timer? _statsTimer;
  bool _started = false;
  bool _connecting = false;
  bool _ingestRepositoryAttached = false;

  static const int maxLineBufferBytes = 64 * 1024;
  static const int maxLineBytes = 8 * 1024;
  String _lineBuffer = "";
  final RegExp _candumpRegex = RegExp(r'can0\s+([0-9a-fA-F]+)#([0-9a-fA-F]*)');

  // RX accounting for the periodic stats log entry.
  int _rxBytesTotal = 0;
  int _rxBytesLogged = 0;
  int _rxLinesTotal = 0;
  int _rxLinesLogged = 0;

  // For simulation history
  double _mockEnergyJ780 = 0.0;
  double _mockSpeedKmh = 0.0;
  double _mockDistanceKm = 0.0;
  double _mockLatDeg = 14.5660;
  double _mockLonDeg = 120.9920;
  double _mockHeadingDeg = 0.0;
  int _mockMotionSequence = 0;
  int _mockGpsSequence = 0;

  final CanTxService? canTxService;
  final CanIngestRepository? canIngestRepository;
  final CanBindings canBindings;

  UsbService(
    this.state,
    TelemetryRecorder recorder,
    GpsSourceManager gpsSourceManager, {
    this.canTxService,
    this.canIngestRepository,
    CanBindings? bindings,
    IngestTransportFactory? transportFactory,
  }) : canBindings = bindings ?? CanBindings(state, recorder, gpsSourceManager),
       _transportFactory = transportFactory;

  bool get _hasLink => _transport?.isOpen ?? false;

  /// Transport for the current link mode, built on first use.
  IngestTransport get _activeTransport =>
      _transport ??= _buildTransport(state.linkMode);

  IngestTransport _buildTransport(LinkMode mode) {
    final factory = _transportFactory;
    if (factory != null) {
      return factory(
        mode,
        debugLog: _log,
        onBytes: _processBytes,
        onDisconnected: _handleDisconnect,
      );
    }
    return switch (mode) {
      LinkMode.usb => UsbSerialTransport(
        state: state,
        debugLog: _log,
        onBytes: _processBytes,
        onDisconnected: _handleDisconnect,
      ),
      LinkMode.ble => BleNusTransport(
        state: state,
        debugLog: _log,
        onBytes: _processBytes,
        onDisconnected: _handleDisconnect,
      ),
    };
  }

  void sendString(String data) {
    final transport = _transport;
    if (transport != null && transport.isOpen) {
      final bytes = Uint8List.fromList(data.codeUnits);
      transport.write(bytes);
      debugLog.info(
        '${transport.sourceLabel.toUpperCase()} TX ${bytes.length} B: '
        '${_trimForLog(data)}',
      );
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
      _closeLink();
      debugLog.info(
        'Simulation mode enabled (${state.linkMode.label} ingest paused)',
      );
      _startMockSimulation();
      return;
    }

    _stopMockSimulation();
    if (!_hasLink) {
      unawaited(_connect());
    }
  }

  void start() {
    _started = true;
    debugLog.info('Vehicle link ingest started (${state.linkMode.label})');
    if (canIngestRepository != null) {
      unawaited(_startIngestRepositoryBridge());
    }

    unawaited(_connect());
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_hasLink && _mockTimer == null) {
        unawaited(_connect());
      }
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _logRxStats();
    });
  }

  void stop() {
    _started = false;
    _reconnectTimer?.cancel();
    _mockTimer?.cancel();
    _statsTimer?.cancel();
    _canFrameSubscription?.cancel();
    _canFrameSubscription = null;
    _canParseErrorSubscription?.cancel();
    _canParseErrorSubscription = null;
    _ingestRepositoryAttached = false;
    final transport = _transport;
    _transport = null;
    unawaited(transport?.close());
    _lineBuffer = '';
    state.setSimulatedState(false);
    state.setConnectionState(false);
    debugLog.info('Vehicle link ingest stopped');
  }

  Future<void> _connect() async {
    if (!_started) {
      return;
    }
    if (state.enableSimulation) {
      _startMockSimulation();
      state.setConnectionState(false);
      return;
    }
    if (_connecting || _hasLink) {
      return;
    }

    _stopMockSimulation();
    _connecting = true;
    try {
      final transport = _activeTransport;
      final opened = await transport.tryConnect();
      // The mode or simulation may have changed while connecting.
      if (!identical(transport, _transport) || state.enableSimulation) {
        if (opened) {
          await transport.close();
        }
        return;
      }
      if (opened) {
        _lineBuffer = '';
        state.setConnectionState(true);
      }
    } finally {
      _connecting = false;
    }
  }

  /// Closes the current link without the disconnect callback and clears the
  /// partial line so bytes from two links never join.
  void _closeLink() {
    final transport = _transport;
    if (transport != null) {
      unawaited(transport.close());
    }
    _lineBuffer = '';
    state.setConnectionState(false);
  }

  void _handleDisconnect(String reason) {
    _lineBuffer = '';
    state.setSimulatedState(false);
    state.setConnectionState(false);
    debugLog.warn(reason);
  }

  /// Enumerates selectable endpoints for the current link mode: USB devices
  /// or serial ports, or advertising/paired BLE ESP32s.
  Future<List<UsbPortOption>> listPortOptions() {
    return _activeTransport.listOptions();
  }

  /// Reacts to a user port selection made in Config -> Connectivity (the
  /// state is already updated by DashboardState.updateUsbPortSelection):
  /// tears down the current connection and reconnects to the chosen port.
  void applyPortSelection(String portId) {
    if (state.linkMode != LinkMode.usb) {
      return;
    }
    if (portId.isEmpty) {
      debugLog.info('USB port selection cleared; using auto-detection');
    } else {
      debugLog.info('USB port selection changed to $portId');
    }
    _reopenLink();
  }

  /// Reacts to a baud rate change made in Config -> Connectivity (the state
  /// is already updated by DashboardState.updateUsbBaudRate): reopens the
  /// current port at the new baud so the change applies without a restart.
  void applyBaudRate(int baud) {
    if (state.linkMode != LinkMode.usb) {
      return;
    }
    debugLog.info('USB baud rate changed to $baud; reconnecting');
    _reopenLink();
  }

  /// Reacts to a BLE device pinned in Config (state already updated).
  void applyBleDeviceSelection(String deviceId) {
    if (state.linkMode != LinkMode.ble) {
      return;
    }
    debugLog.info(
      deviceId.isEmpty
          ? 'BLE device selection cleared'
          : 'BLE device selection changed to $deviceId',
    );
    _reopenLink(connectEvenIfIdle: true);
  }

  /// Switches the transport (state already updated by
  /// DashboardState.updateLinkMode). Simulation keeps running if enabled.
  void applyLinkMode(LinkMode mode) {
    final previous = _transport;
    _transport = null;
    if (previous != null) {
      unawaited(previous.close());
    }
    _lineBuffer = '';
    if (!state.isSimulated) {
      state.setConnectionState(false);
    }
    debugLog.info('Vehicle link mode changed to ${mode.label}');
    if (!state.enableSimulation) {
      unawaited(_connect());
    }
  }

  Future<BlePairResult> pairBleDevice(String deviceId) async {
    final transport = _activeTransport;
    if (transport is! BleNusTransport) {
      return BlePairResult.unsupported;
    }
    final result = await transport.pair(deviceId);
    if (result == BlePairResult.bonded && !state.enableSimulation) {
      unawaited(_connect());
    }
    return result;
  }

  Future<bool> unpairBleDevice(String deviceId) async {
    final transport = _activeTransport;
    if (transport is! BleNusTransport) {
      return false;
    }
    final wasOpen = transport.isOpen;
    final removed = await transport.unpair(deviceId);
    if (wasOpen && !transport.isOpen) {
      _lineBuffer = '';
      state.setConnectionState(false);
    }
    return removed;
  }

  Future<BleBondState> bleBondState(String deviceId) async {
    final transport = _activeTransport;
    if (transport is! BleNusTransport) {
      return BleBondState.unknown;
    }
    return transport.bondState(deviceId);
  }

  void _reopenLink({bool connectEvenIfIdle = false}) {
    final hadLink = _hasLink;
    final wasSimulated = state.isSimulated;
    _closeLink();
    if ((hadLink || connectEvenIfIdle) &&
        !wasSimulated &&
        !state.enableSimulation) {
      unawaited(_connect());
    }
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
      // drive-and-stop cycles keep telemetry flowing while stationary.
      // Logging can start or stop regardless of vehicle motion. While a
      // session is logging, the full race physics run.
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
      // PEDAL_STATUS byte 2: deadman_active is bit 0, brake_active is bit 2.
      int flags = 0x01 | (braking ? 0x04 : 0x00);
      String tHex = throttle15bit.toRadixString(16).padLeft(4, '0');
      String tLe = tHex.substring(2, 4) + tHex.substring(0, 2);
      String fHex = flags.toRadixString(16).padLeft(2, '0');
      _emitSimulatedFrame(CanIds.pedalStatus, '$tLe${fHex}000000');

      // 2. PHYSICS ENGINE
      if (braking) {
        _mockSpeedKmh -= 4.0;
        if (_mockSpeedKmh < 0) _mockSpeedKmh = 0;
      } else {
        _mockSpeedKmh += (throttle / 100.0) * 1.5;
        if (_mockSpeedKmh > 160) _mockSpeedKmh = 160;
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
            (stepKm * sin(headingRad)) /
            (111.320 * max(cos(latRad).abs(), 0.2));
      }

      // --- SEND VEHICLE MOTION (0x400) ---
      final motionBytes = Uint8List(8);
      final motionData = ByteData.sublistView(motionBytes);
      motionData.setUint16(
        0,
        (_mockSpeedKmh / 0.01).round().clamp(0, 65535).toInt(),
        Endian.little,
      );
      motionData.setUint32(
        2,
        (_mockDistanceKm * 10000).round().clamp(0, 0xFFFFFFFF).toInt(),
        Endian.little,
      );
      motionBytes[6] = 1; // motion_valid
      _mockMotionSequence = (_mockMotionSequence + 1) & 0xFF;
      motionBytes[7] = _mockMotionSequence;
      _emitSimulatedFrame(CanIds.vehicleMotion, _bytesToHex(motionBytes));

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
      _emitSimulatedFrame(CanIds.packPower, '$pVle$pAle');

      // --- SEND AUXILIARY POWER (0x311) ---
      const auxVolts = 12.4;
      const auxAmps = 1.5;
      final auxVRaw = (auxVolts / 0.003125).round();
      final auxARaw = (auxAmps / 0.0012).round();
      final auxVle =
          (auxVRaw & 0xFF).toRadixString(16).padLeft(2, '0') +
          ((auxVRaw >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      final auxAle =
          (auxARaw & 0xFF).toRadixString(16).padLeft(2, '0') +
          ((auxARaw >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
      _emitSimulatedFrame(CanIds.auxPower, '$auxVle$auxAle');

      // --- SEND ENERGY (0x312) ---
      _mockEnergyJ780 += (volts * amps) * 0.1;
      int eRaw = (_mockEnergyJ780 / 0.00768).toInt();
      // Pack 40-bit Energy (5 bytes)
      String eLe = "";
      for (int i = 0; i < 5; i++) {
        eLe += ((eRaw >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0');
      }
      _emitSimulatedFrame(CanIds.packEnergy, eLe);

      // 4. EXTERNAL GPS FRAMES
      const int mockSatellites = 11;
      const int mockStatusFlags = 0x0F;
      final gpsStatusBytes = Uint8List(4);
      gpsStatusBytes[0] = mockSatellites;
      gpsStatusBytes[1] = mockStatusFlags;
      _mockGpsSequence = (_mockGpsSequence + 1) & 0xFF;
      gpsStatusBytes[2] = _mockGpsSequence;
      _emitSimulatedFrame(CanIds.gpsStatus, _bytesToHex(gpsStatusBytes));

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
      _emitSimulatedFrame(CanIds.gpsPosition, _bytesToHex(gpsPositionBytes));

      final gpsMotionBytes = Uint8List(4);
      final gpsMotionData = ByteData.sublistView(gpsMotionBytes);
      gpsMotionData.setUint16(
        0,
        (_mockSpeedKmh / 0.01).round().clamp(0, 65535).toInt(),
        Endian.little,
      );
      gpsMotionData.setUint16(
        2,
        ((_mockHeadingDeg % 360.0) * 100).round().clamp(0, 35999).toInt(),
        Endian.little,
      );
      _emitSimulatedFrame(CanIds.gpsMotion, _bytesToHex(gpsMotionBytes));
    });
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
      _lineBuffer = keepFrom > 0 ? _lineBuffer.substring(keepFrom) : '';
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
    state.updateRawCan(frame.canId, frame.payloadHex, source: frame.source);

    final payloadBytes = _hexToBytes(frame.payloadHex);
    try {
      final decoded = decodeCanFrame(frame.canId, payloadBytes);
      if (decoded == null) {
        return;
      }
      canBindings.handle(decoded, receivedAtUtc: frame.receivedAtUtc);
    } on CanDecodeException catch (error) {
      debugLog.warn(
        'CAN decode error [${error.message}] id=0x${frame.canId.toRadixString(16)} '
        'payload=${frame.payloadHex}',
      );
    }
  }

  String _resolveIngestSource() {
    return state.isSimulated
        ? 'simulation'
        : (_transport?.sourceLabel ?? state.linkMode.name);
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
}
