import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/ingest/usb_debug_log.dart';
import 'package:telemetry_dashboard/repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/models/telemetry/can_bindings.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';

/// A selectable ingest endpoint. For BLE: id = remoteId (MAC on Android,
/// UUID on iOS), label = "<name> (<id>) <rssi>".
///
/// NOTE: the class/file name still says "Usb" on purpose so the coordinator,
/// DashboardState and Config view keep compiling unchanged. Rename once the
/// BLE link is verified on the car.
class UsbPortOption {
  final String id;
  final String label;

  const UsbPortOption({required this.id, required this.label});
}

/// ESP32 -> phone ingest over BLE using the Nordic UART Service (NUS).
///
/// Flow: scan -> pick the ESP32 that is advertising (NUS UUID or
/// [deviceNamePrefix]) -> connect -> negotiate MTU -> discover NUS ->
/// subscribe to the TX characteristic (notify) -> feed every notification
/// into the same line-framed candump pipeline the USB path used. If the link
/// drops, the 3 s reconnect timer scans again, so ingest resumes by itself.
class UsbService {
  final DashboardState state;
  final UsbDebugLogStore debugLog = UsbDebugLogStore();

  // Nordic UART Service. "TX/RX" are named from the ESP32's point of view.
  static final Guid nusServiceGuid = Guid(
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  );
  static final Guid nusRxGuid = Guid(
    '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  ); // phone -> ESP32 (write)
  static final Guid nusTxGuid = Guid(
    '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
  ); // ESP32 -> phone (notify)

  /// Advertised-name prefix used when the NUS UUID is not in the advertising
  /// packet. Override with --dart-define=BLE_NAME_PREFIX=MyCar
  static const String deviceNamePrefix = String.fromEnvironment(
    'BLE_NAME_PREFIX',
    defaultValue: 'EcoArchers',
  );

  static const int desiredMtu = 247;
  static const Duration scanTimeout = Duration(seconds: 8);
  static const Duration connectTimeout = Duration(seconds: 12);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar; // phone -> ESP32
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<CanFrameMessage>? _canFrameSubscription;
  StreamSubscription<CanParseError>? _canParseErrorSubscription;
  Timer? _reconnectTimer;
  Timer? _mockTimer;
  Timer? _statsTimer;
  bool _connecting = false;
  bool _ingestRepositoryAttached = false;
  Future<void> _txChain = Future<void>.value();

  static const int maxLineBufferBytes = 64 * 1024;
  static const int maxLineBytes = 8 * 1024;
  String _lineBuffer = "";
  final RegExp _candumpRegex = RegExp(r'can0\s+([0-9a-fA-F]+)#([0-9a-fA-F]*)');

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
  }) : canBindings = bindings ?? CanBindings(state, recorder, gpsSourceManager);

  bool get _hasLink => _device != null;

  // ---------------------------------------------------------------- TX ----

  /// Phone -> ESP32 (e.g. CAN TX requests). Chunked to the negotiated MTU and
  /// serialized so chunks cannot interleave.
  void sendString(String data) {
    final bytes = Uint8List.fromList(data.codeUnits);
    final rx = _rxChar;
    final device = _device;
    if (rx != null && device != null) {
      debugLog.info('TX ${bytes.length} B: ${_trimForLog(data)}');
      _txChain = _txChain
          .then((_) => _writeChunks(device, rx, bytes))
          .catchError((Object e) {
            _logThrottled('ble_tx_error', 'BLE TX failed: $e');
          });
    } else if (state.isSimulated) {
      debugPrint("SIMULATED TX: $data");
    }
  }

  Future<void> _writeChunks(
    BluetoothDevice device,
    BluetoothCharacteristic rx,
    Uint8List bytes,
  ) async {
    final chunk = max(20, device.mtuNow - 3);
    final noRsp = rx.properties.writeWithoutResponse;
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = min(i + chunk, bytes.length);
      await rx.write(bytes.sublist(i, end), withoutResponse: noRsp);
    }
  }

  // --------------------------------------------------------- lifecycle ----

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
      unawaited(_teardownLink());
      state.setConnectionState(false);
      debugLog.info('Simulation mode enabled (BLE ingest paused)');
      _startMockSimulation();
      return;
    }

    _stopMockSimulation();
    if (!_hasLink) {
      unawaited(_connect());
    }
  }

  void start() {
    debugLog.info('BLE ingest started');
    if (canIngestRepository != null) {
      unawaited(_startIngestRepositoryBridge());
    }

    unawaited(_connect());
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_hasLink && !_connecting && _mockTimer == null) {
        unawaited(_connect());
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
    _canFrameSubscription?.cancel();
    _canFrameSubscription = null;
    _canParseErrorSubscription?.cancel();
    _canParseErrorSubscription = null;
    _ingestRepositoryAttached = false;
    unawaited(_teardownLink());
    state.setSimulatedState(false);
    state.setConnectionState(false);
    debugLog.info('BLE ingest stopped');
  }

  // ------------------------------------------------------- connection ----

  Future<void> _connect() async {
    if (state.enableSimulation) {
      _startMockSimulation();
      state.setConnectionState(false);
      return;
    }
    if (_connecting || _hasLink) {
      return;
    }

    _connecting = true;
    try {
      if (!await _ensureAdapterReady()) {
        return;
      }

      final target = await _scanForEsp();
      if (target == null) {
        _logThrottled(
          'ble_no_device',
          'No ESP32 advertising (NUS or "$deviceNamePrefix*"); retrying...',
        );
        return;
      }

      _stopMockSimulation();
      await _openDevice(target);
    } catch (e) {
      _logThrottled('ble_connect_error', 'BLE connect failed: $e');
      await _teardownLink();
      state.setConnectionState(false);
    } finally {
      _connecting = false;
    }
  }

  Future<bool> _ensureAdapterReady() async {
    if (!await FlutterBluePlus.isSupported) {
      _logThrottled('ble_unsupported', 'Bluetooth LE not supported on device.');
      return false;
    }

    var adapter = FlutterBluePlus.adapterStateNow;
    if (adapter == BluetoothAdapterState.unknown) {
      adapter = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
    }
    if (adapter == BluetoothAdapterState.on) {
      return true;
    }

    _logThrottled('ble_adapter_off', 'Bluetooth is $adapter; enable it.');
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await FlutterBluePlus.turnOn(); // system prompt; throws if denied
      } catch (_) {}
    }
    return false; // the next reconnect tick retries
  }

  bool _isEspCandidate(ScanResult r) {
    final adv = r.advertisementData;
    if (adv.serviceUuids.contains(nusServiceGuid)) {
      return true;
    }
    final name = adv.advName.isNotEmpty ? adv.advName : r.device.platformName;
    return name.isNotEmpty && name.startsWith(deviceNamePrefix);
  }

  String _describeScan(ScanResult r) {
    final adv = r.advertisementData;
    final name = adv.advName.isNotEmpty
        ? adv.advName
        : (r.device.platformName.isNotEmpty ? r.device.platformName : '?');
    return '$name (${r.device.remoteId.str}) ${r.rssi} dBm';
  }

  /// Scans until an ESP32 is seen advertising. If a device is pinned in
  /// Config, only that remoteId matches; otherwise the strongest candidate
  /// seen within a short settle window wins.
  Future<ScanResult?> _scanForEsp() async {
    final pinned = state.usbPortSelection;
    ScanResult? best;
    final firstHit = Completer<void>();

    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (!_isEspCandidate(r)) {
          continue;
        }
        if (pinned.isNotEmpty && r.device.remoteId.str != pinned) {
          continue;
        }
        if (best == null || r.rssi > best!.rssi) {
          best = r;
        }
        if (!firstHit.isCompleted) {
          firstHit.complete();
        }
      }
    }, onError: (Object e) => debugLog.warn('BLE scan stream error: $e'));

    try {
      await FlutterBluePlus.startScan(
        timeout: scanTimeout,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await Future.any<void>([
        firstHit.future,
        Future<void>.delayed(scanTimeout),
      ]);
      if (best != null && pinned.isEmpty) {
        // Settle briefly so a stronger nearby ESP32 can win over the first.
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    return best;
  }

  Future<void> _openDevice(ScanResult found) async {
    final device = found.device;
    debugLog.info('Found ESP32: ${_describeScan(found)}; connecting...');

    await device.connect(timeout: connectTimeout, mtu: desiredMtu);
    _device = device;

    // Subscribe only after connect(): connectionState replays the current
    // (disconnected) value on listen and would trigger a false disconnect.
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _handleDisconnect();
      }
    });

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      } catch (_) {}
    }

    final services = await device.discoverServices();
    BluetoothCharacteristic? tx;
    BluetoothCharacteristic? rx;
    for (final s in services) {
      if (s.uuid != nusServiceGuid) {
        continue;
      }
      for (final c in s.characteristics) {
        if (c.uuid == nusTxGuid) tx = c;
        if (c.uuid == nusRxGuid) rx = c;
      }
    }
    if (tx == null) {
      throw StateError('Nordic UART TX characteristic not found on device');
    }

    _rxChar = rx;
    _lineBuffer = '';

    // Listen first, then enable notifications, so the first packet is kept.
    _notifySub = tx.onValueReceived.listen(
      _onNotification,
      onError: (Object e) {
        debugLog.error('BLE notify stream error: $e');
        _handleDisconnect();
      },
    );
    await tx.setNotifyValue(true);

    state.setConnectionState(true);
    debugLog.info(
      'BLE link up: ${_describeScan(found)} '
      'MTU ${device.mtuNow} (payload ${device.mtuNow - 3} B)',
    );
  }

  void _onNotification(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    _processBytes(data is Uint8List ? data : Uint8List.fromList(data));
  }

  void _handleDisconnect() {
    if (!_hasLink) {
      return;
    }
    unawaited(_teardownLink());
    state.setSimulatedState(false);
    state.setConnectionState(false);
    debugLog.warn('BLE device disconnected; will rescan');
  }

  Future<void> _teardownLink() async {
    final device = _device;
    _device = null;
    _rxChar = null;
    _lineBuffer = '';

    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;

    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  /// Enumerates ESP32s currently advertising (4 s scan) so the Config screen
  /// can pin one. The connected device is always listed.
  Future<List<UsbPortOption>> listPortOptions() async {
    final found = <String, UsbPortOption>{};

    final device = _device;
    if (device != null) {
      found[device.remoteId.str] = UsbPortOption(
        id: device.remoteId.str,
        label:
            '${device.platformName.isEmpty ? 'ESP32' : device.platformName} '
            '(${device.remoteId.str}) - connected',
      );
    }

    if (_connecting || !await FlutterBluePlus.isSupported) {
      return found.values.toList();
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      return found.values.toList();
    }

    _connecting = true; // keep the auto-reconnect scan out of the way
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (_isEspCandidate(r)) {
          found[r.device.remoteId.str] = UsbPortOption(
            id: r.device.remoteId.str,
            label: _describeScan(r),
          );
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4),
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await Future<void>.delayed(const Duration(milliseconds: 4200));
    } catch (e) {
      debugLog.warn('BLE device enumeration failed: $e');
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      _connecting = false;
    }
    return found.values.toList();
  }

  /// Reacts to a device pinned/unpinned in Config (state already updated by
  /// DashboardState.updateUsbPortSelection): drops the link and rescans.
  void applyPortSelection(String portId) {
    final hadLink = _hasLink;
    final wasSimulated = state.isSimulated;
    unawaited(_teardownLink());
    state.setConnectionState(false);

    if (portId.isEmpty) {
      debugLog.info('BLE device selection cleared; using auto-detection');
    } else {
      debugLog.info('BLE device selection changed to $portId');
    }
    if (hadLink && !wasSimulated && !state.enableSimulation) {
      unawaited(_connect());
    }
  }

  /// Kept so existing callers compile. BLE has no baud rate.
  void applyBaudRate(int baud) {
    debugLog.info('Baud rate ($baud) ignored: BLE link has no baud setting');
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
}