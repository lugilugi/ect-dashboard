import 'dart:collection';

import 'package:flutter/foundation.dart';

enum UsbDebugLevel { info, warn, error }

class UsbDebugEntry {
  final DateTime atUtc;
  final UsbDebugLevel level;
  final String message;

  const UsbDebugEntry({
    required this.atUtc,
    required this.level,
    required this.message,
  });
}

/// Bounded ring buffer of USB/serial ingest events, surfaced in
/// Config -> Connectivity so a device can be diagnosed on the pit wall
/// without console access. Entry volume is throttled by [UsbService]
/// (periodic RX stats, deduped connect failures) so listeners are not
/// flooded by the 100 Hz CAN stream.
class UsbDebugLogStore extends ChangeNotifier {
  static const int maxEntries = 300;

  final Queue<UsbDebugEntry> _entries = Queue<UsbDebugEntry>();

  List<UsbDebugEntry> get entries => List<UsbDebugEntry>.unmodifiable(_entries);

  int get count => _entries.length;

  void info(String message) => _add(UsbDebugLevel.info, message);

  void warn(String message) => _add(UsbDebugLevel.warn, message);

  void error(String message) => _add(UsbDebugLevel.error, message);

  void clear() {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    notifyListeners();
  }

  void _add(UsbDebugLevel level, String message) {
    _entries.add(
      UsbDebugEntry(atUtc: DateTime.now().toUtc(), level: level, message: message),
    );
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }
}
