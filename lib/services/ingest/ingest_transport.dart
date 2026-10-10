import 'dart:typed_data';

import 'package:telemetry_dashboard/services/ingest/usb_debug_log.dart';

/// Vehicle link transport selected in Config -> Connectivity.
enum LinkMode {
  usb,
  ble;

  String get label => name.toUpperCase();

  static LinkMode fromWire(String? value) =>
      value == ble.name ? LinkMode.ble : LinkMode.usb;
}

/// A selectable ingest endpoint: Android usb_serial device (id =
/// deviceName), desktop serial port name (id = port name like COM5), or BLE
/// peripheral (id = Android remote MAC address).
class UsbPortOption {
  final String id;
  final String label;

  const UsbPortOption({required this.id, required this.label});
}

/// Byte link between the app and the vehicle ESP32. Transports only move
/// bytes: line framing, CAN decode, command acks and simulation stay in
/// UsbService so every link feeds the identical pipeline.
abstract class IngestTransport {
  IngestTransport({
    required this.debugLog,
    required this.onBytes,
    required this.onDisconnected,
  });

  final IngestLinkLog debugLog;
  final void Function(Uint8List bytes) onBytes;

  /// Called once per established link when it drops on its own (unplug,
  /// out of range). Not called for [close].
  final void Function(String reason) onDisconnected;

  /// Diagnostic label for the debug CAN log; telemetry events keep their own
  /// source.
  String get sourceLabel;

  bool get isOpen;

  /// Makes one connection attempt. The UsbService reconnect timer owns
  /// retries, so failures log (throttled) and return false.
  Future<bool> tryConnect();

  void write(Uint8List bytes);

  Future<void> close();

  Future<List<UsbPortOption>> listOptions();
}

/// Debug log wrapper shared by UsbService and its transports. Dedupes
/// repeated connect failures so the in-app log is not flooded by the
/// 3-second reconnect timer.
class IngestLinkLog {
  IngestLinkLog(this.store);

  final UsbDebugLogStore store;
  final Map<String, DateTime> _lastThrottledLogAt = {};

  void info(String message) => store.info(message);

  void warn(String message) => store.warn(message);

  void error(String message) => store.error(message);

  void throttled(
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
    store.warn(message);
  }
}
