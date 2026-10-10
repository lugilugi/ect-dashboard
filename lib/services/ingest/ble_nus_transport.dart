import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/ingest/ingest_transport.dart';

/// Android Bluetooth bond state of a remote device.
enum BleBondState { none, bonding, bonded, unknown }

/// Outcome of a user-initiated pairing attempt from Config.
enum BlePairResult { bonded, failed, timeout, permissionDenied, unsupported }

/// Splits [bytes] into ATT write payloads for [mtu] (3 bytes of ATT header
/// per packet). Order is preserved; the ESP32 reassembles on newline.
List<Uint8List> chunkForMtu(Uint8List bytes, int mtu) {
  final size = max(20, mtu - 3);
  return [
    for (var i = 0; i < bytes.length; i += size)
      Uint8List.sublistView(bytes, i, min(i + size, bytes.length)),
  ];
}

/// Android bonding through the app's own MethodChannel (MainActivity
/// BleBondHandler); flutter_reactive_ble has no bonding API. Android also
/// prompts on its own when an encrypted characteristic is first accessed,
/// but explicit pairing keeps the reconnect loop from raising dialogs.
class BleBondChannel {
  static const MethodChannel _channel = MethodChannel('ect_dashboard/ble_bond');

  Future<BleBondState> bondState(String deviceId) async {
    final value = await _channel.invokeMethod<String>('bondState', {
      'id': deviceId,
    });
    return switch (value) {
      'bonded' => BleBondState.bonded,
      'bonding' => BleBondState.bonding,
      'none' => BleBondState.none,
      _ => BleBondState.unknown,
    };
  }

  Future<bool> createBond(String deviceId) async {
    return await _channel.invokeMethod<bool>('createBond', {'id': deviceId}) ??
        false;
  }

  Future<bool> removeBond(String deviceId) async {
    return await _channel.invokeMethod<bool>('removeBond', {'id': deviceId}) ??
        false;
  }

  /// Bonded devices as {id, name} maps.
  Future<List<Map<String, String>>> bondedDevices() async {
    final raw = await _channel.invokeListMethod<Object?>('bondedDevices');
    return [
      for (final item in raw ?? const <Object?>[])
        if (item is Map)
          {'id': '${item['id'] ?? ''}', 'name': '${item['name'] ?? ''}'},
    ];
  }
}

/// ESP32-C3 link over BLE using the Nordic UART Service (NUS), Android only.
/// The ESP32 sends the same newline-framed bytes it writes to USB, so
/// UsbService feeds notifications into the unchanged line pipeline. The
/// firmware contract (bonding, MTU, batching) is in
/// docs/implementation/ble-link.md.
///
/// The reconnect loop never scans: it connects directly to the pinned,
/// bonded device, because Android throttles apps that start more than five
/// scans per 30 s. Scanning only runs from the Config refresh action.
class BleNusTransport extends IngestTransport {
  BleNusTransport({
    required this.state,
    required super.debugLog,
    required super.onBytes,
    required super.onDisconnected,
    FlutterReactiveBle? ble,
    BleBondChannel? bonds,
  }) : _bleOverride = ble,
       bonds = bonds ?? BleBondChannel();

  // "TX/RX" are named from the ESP32's point of view.
  static final Uuid nusService = Uuid.parse(
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  );
  static final Uuid nusRx = Uuid.parse(
    '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  ); // phone -> ESP32 (write)
  static final Uuid nusTx = Uuid.parse(
    '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
  ); // ESP32 -> phone (notify)

  /// Advertised-name prefix accepted when the NUS UUID is not in the
  /// advertising packet. Override with --dart-define=BLE_NAME_PREFIX=MyCar.
  static const String deviceNamePrefix = String.fromEnvironment(
    'BLE_NAME_PREFIX',
    defaultValue: 'EcoArchers',
  );

  static const int desiredMtu = 247;
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration scanDuration = Duration(seconds: 4);
  static const Duration pairTimeout = Duration(seconds: 60);

  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final DashboardState state;
  final BleBondChannel bonds;
  final FlutterReactiveBle? _bleOverride;
  FlutterReactiveBle? _bleInstance;

  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _notifySub;
  QualifiedCharacteristic? _rxChar;
  bool _rxWithoutResponse = false;
  String? _deviceId;
  int _mtu = 23;
  bool _open = false;
  bool _connecting = false;
  Future<void> _txChain = Future<void>.value();

  // Created lazily so non-Android builds never touch the plugin.
  FlutterReactiveBle get _ble =>
      _bleOverride ?? (_bleInstance ??= FlutterReactiveBle());

  @override
  String get sourceLabel => 'ble';

  @override
  bool get isOpen => _open;

  int get mtu => _mtu;

  @override
  Future<bool> tryConnect() async {
    if (_open || _connecting) {
      return _open;
    }
    if (!isSupportedPlatform) {
      debugLog.throttled(
        'ble_unsupported_platform',
        'BLE link is Android-only; switch Config -> Connectivity to USB.',
      );
      return false;
    }

    final deviceId = state.bleDeviceSelection;
    if (deviceId.isEmpty) {
      debugLog.throttled(
        'ble_no_device',
        'No BLE device selected; pick and PAIR one in Config -> Connectivity.',
      );
      return false;
    }

    _connecting = true;
    try {
      if (!await _hasPermissions(request: false)) {
        debugLog.throttled(
          'ble_permission',
          'Bluetooth permission not granted; open Config -> Connectivity '
              'to grant it.',
        );
        return false;
      }
      if (!await _adapterReady()) {
        return false;
      }

      final bond = await bonds.bondState(deviceId);
      if (bond != BleBondState.bonded) {
        debugLog.throttled(
          'ble_not_bonded',
          'BLE device $deviceId is not paired (${bond.name}); '
              'tap PAIR in Config -> Connectivity.',
        );
        return false;
      }

      return await _openLink(deviceId);
    } catch (e) {
      debugLog.throttled('ble_connect_error', 'BLE connect failed: $e');
      await _teardown();
      return false;
    } finally {
      _connecting = false;
    }
  }

  Future<bool> _openLink(String deviceId) async {
    final ble = _ble;
    final connected = Completer<String?>();

    _connection = ble
        .connectToDevice(
          id: deviceId,
          servicesWithCharacteristicsToDiscover: {
            nusService: [nusRx, nusTx],
          },
          connectionTimeout: connectTimeout,
        )
        .listen(
          (update) {
            switch (update.connectionState) {
              case DeviceConnectionState.connected:
                if (!connected.isCompleted) {
                  connected.complete(null);
                }
              case DeviceConnectionState.disconnected:
                final detail = update.failure?.message ?? 'disconnected';
                if (!connected.isCompleted) {
                  connected.complete(detail);
                } else {
                  _handleLinkLost('BLE device disconnected ($detail)');
                }
              case DeviceConnectionState.connecting:
              case DeviceConnectionState.disconnecting:
                break;
            }
          },
          onError: (Object e) {
            if (!connected.isCompleted) {
              connected.complete('$e');
            } else {
              _handleLinkLost('BLE connection error: $e');
            }
          },
        );

    final failure = await connected.future.timeout(
      connectTimeout + const Duration(seconds: 2),
      onTimeout: () => 'timeout',
    );
    if (failure != null) {
      await _teardown();
      debugLog.throttled(
        'ble_connect_failed',
        'BLE connect to $deviceId failed: $failure; retrying...',
      );
      return false;
    }

    try {
      _mtu = await ble.requestMtu(deviceId: deviceId, mtu: desiredMtu);
    } catch (e) {
      _mtu = 23;
      debugLog.warn('BLE MTU request failed ($e); using 23');
    }
    try {
      await ble.requestConnectionPriority(
        deviceId: deviceId,
        priority: ConnectionPriority.highPerformance,
      );
    } catch (e) {
      debugLog.warn('BLE connection priority request failed: $e');
    }

    final services = await ble.getDiscoveredServices(deviceId);
    Characteristic? rx;
    Characteristic? tx;
    for (final service in services) {
      if (service.id != nusService) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        if (characteristic.id == nusRx) rx = characteristic;
        if (characteristic.id == nusTx) tx = characteristic;
      }
    }
    if (rx == null || tx == null) {
      await _teardown();
      debugLog.throttled(
        'ble_no_nus',
        'BLE device $deviceId has no Nordic UART service; check firmware.',
      );
      return false;
    }

    _deviceId = deviceId;
    _rxChar = QualifiedCharacteristic(
      serviceId: nusService,
      characteristicId: nusRx,
      deviceId: deviceId,
    );
    _rxWithoutResponse = rx.isWritableWithoutResponse;

    // The firmware requires an encrypted, authenticated link for the CCCD
    // write; a lost or mismatched bond surfaces here as an error.
    _notifySub = ble
        .subscribeToCharacteristic(
          QualifiedCharacteristic(
            serviceId: nusService,
            characteristicId: nusTx,
            deviceId: deviceId,
          ),
        )
        .listen(
          (data) {
            if (data.isNotEmpty) {
              onBytes(data is Uint8List ? data : Uint8List.fromList(data));
            }
          },
          onError: (Object e) {
            _handleLinkLost(
              'BLE notify failed (re-pair if authentication failed): $e',
            );
          },
        );

    _open = true;
    debugLog.info(
      'BLE link up: $deviceId MTU $_mtu (payload ${_mtu - 3} B, '
      'write ${_rxWithoutResponse ? 'without' : 'with'} response)',
    );
    return true;
  }

  Future<bool> _adapterReady() async {
    var status = _ble.status;
    if (status == BleStatus.unknown) {
      status = await _ble.statusStream
          .firstWhere((s) => s != BleStatus.unknown)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => BleStatus.unknown,
          );
    }
    if (status == BleStatus.ready) {
      return true;
    }
    debugLog.throttled('ble_adapter', 'Bluetooth not ready (${status.name}).');
    return false;
  }

  Future<bool> _hasPermissions({required bool request}) async {
    final permissions = [Permission.bluetoothScan, Permission.bluetoothConnect];
    if (request) {
      final results = await permissions.request();
      return results.values.every((s) => s.isGranted);
    }
    for (final permission in permissions) {
      if (!await permission.isGranted) {
        return false;
      }
    }
    return true;
  }

  void _handleLinkLost(String reason) {
    if (!_open) {
      return;
    }
    unawaited(_teardown());
    onDisconnected(reason);
  }

  Future<void> _teardown() async {
    _open = false;
    _deviceId = null;
    _rxChar = null;
    _txChain = Future<void>.value();
    final notify = _notifySub;
    _notifySub = null;
    final connection = _connection;
    _connection = null;
    await notify?.cancel();
    // Cancelling the connection stream disconnects the device.
    await connection?.cancel();
  }

  /// Phone -> ESP32. Chunked to the negotiated MTU and serialized so the
  /// chunks of one line never interleave with another.
  @override
  void write(Uint8List bytes) {
    final rx = _rxChar;
    if (!_open || rx == null) {
      return;
    }
    final ble = _ble;
    final withoutResponse = _rxWithoutResponse;
    final chunks = chunkForMtu(bytes, _mtu);
    _txChain = _txChain
        .then((_) async {
          for (final chunk in chunks) {
            if (withoutResponse) {
              await ble.writeCharacteristicWithoutResponse(rx, value: chunk);
            } else {
              await ble.writeCharacteristicWithResponse(rx, value: chunk);
            }
          }
        })
        .catchError((Object e) {
          debugLog.throttled('ble_tx_error', 'BLE TX failed: $e');
        });
  }

  @override
  Future<void> close() => _teardown();

  /// Scans briefly for advertising ESP32s (NUS UUID or name prefix) and lists
  /// them with already-bonded matches and the current selection, so Config
  /// can pin one. Requests Bluetooth permissions (user-initiated only).
  @override
  Future<List<UsbPortOption>> listOptions() async {
    final found = <String, UsbPortOption>{};
    if (!isSupportedPlatform) {
      return const [];
    }

    final selected = state.bleDeviceSelection;
    if (selected.isNotEmpty) {
      found[selected] = UsbPortOption(
        id: selected,
        label: _deviceId == selected ? '$selected - connected' : selected,
      );
    }

    if (!await _hasPermissions(request: true)) {
      debugLog.warn('Bluetooth permission denied; cannot scan.');
      return found.values.toList();
    }

    try {
      for (final device in await bonds.bondedDevices()) {
        final id = device['id'] ?? '';
        final name = device['name'] ?? '';
        if (id.isNotEmpty &&
            (id == selected || name.startsWith(deviceNamePrefix))) {
          found[id] = UsbPortOption(id: id, label: '$name ($id) - paired');
        }
      }
    } catch (e) {
      debugLog.warn('Bonded device list failed: $e');
    }

    if (!await _adapterReady()) {
      return found.values.toList();
    }

    StreamSubscription<DiscoveredDevice>? scan;
    try {
      scan = _ble
          .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
          .listen((device) {
            final matches =
                device.serviceUuids.contains(nusService) ||
                (device.name.isNotEmpty &&
                    device.name.startsWith(deviceNamePrefix));
            if (!matches) {
              return;
            }
            final name = device.name.isEmpty ? 'ESP32' : device.name;
            final paired = found[device.id]?.label.endsWith('paired') ?? false;
            found[device.id] = UsbPortOption(
              id: device.id,
              label:
                  '$name (${device.id}) ${device.rssi} dBm'
                  '${paired ? ' - paired' : ''}',
            );
          }, onError: (Object e) => debugLog.warn('BLE scan error: $e'));
      await Future<void>.delayed(scanDuration);
    } finally {
      await scan?.cancel();
    }
    return found.values.toList();
  }

  Future<BleBondState> bondState(String deviceId) async {
    if (!isSupportedPlatform || deviceId.isEmpty) {
      return BleBondState.unknown;
    }
    try {
      return await bonds.bondState(deviceId);
    } catch (e) {
      debugLog.warn('BLE bond state failed: $e');
      return BleBondState.unknown;
    }
  }

  /// Starts Android bonding (system passkey dialog) and waits for it to
  /// finish. Scan first so Android knows the device is LE.
  Future<BlePairResult> pair(String deviceId) async {
    if (!isSupportedPlatform || deviceId.isEmpty) {
      return BlePairResult.unsupported;
    }
    if (!await _hasPermissions(request: true)) {
      return BlePairResult.permissionDenied;
    }
    try {
      if (await bonds.bondState(deviceId) == BleBondState.bonded) {
        return BlePairResult.bonded;
      }
      debugLog.info('BLE pairing with $deviceId; enter the passkey when asked');
      if (!await bonds.createBond(deviceId)) {
        debugLog.warn('BLE pairing with $deviceId could not start');
        return BlePairResult.failed;
      }
      final deadline = DateTime.now().add(pairTimeout);
      var sawBonding = false;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final bond = await bonds.bondState(deviceId);
        if (bond == BleBondState.bonded) {
          debugLog.info('BLE paired with $deviceId');
          return BlePairResult.bonded;
        }
        if (bond == BleBondState.bonding) {
          sawBonding = true;
        } else if (sawBonding) {
          debugLog.warn('BLE pairing with $deviceId rejected or cancelled');
          return BlePairResult.failed;
        }
      }
      debugLog.warn('BLE pairing with $deviceId timed out');
      return BlePairResult.timeout;
    } catch (e) {
      debugLog.warn('BLE pairing failed: $e');
      return BlePairResult.failed;
    }
  }

  /// Drops the link if it is to [deviceId] and removes the Android bond.
  Future<bool> unpair(String deviceId) async {
    if (!isSupportedPlatform || deviceId.isEmpty) {
      return false;
    }
    if (_deviceId == deviceId) {
      await _teardown();
    }
    try {
      final removed = await bonds.removeBond(deviceId);
      debugLog.info(
        removed
            ? 'BLE bond removed for $deviceId'
            : 'Could not remove bond for $deviceId; forget it in Android '
                  'Bluetooth settings',
      );
      return removed;
    } catch (e) {
      debugLog.warn('BLE unpair failed: $e');
      return false;
    }
  }
}
