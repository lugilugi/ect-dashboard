import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/ingest/ingest_transport.dart';
import 'package:usb_serial/usb_serial.dart';

/// USB serial link: Android usb_serial, falling back to desktop
/// libserialport (Windows/macOS/Linux) when the plugin is unavailable.
class UsbSerialTransport extends IngestTransport {
  UsbSerialTransport({
    required this.state,
    required super.debugLog,
    required super.onBytes,
    required super.onDisconnected,
  });

  final DashboardState state;

  UsbPort? _port;
  StreamSubscription<Uint8List>? _subscription;
  bool _usbPluginUnavailable = false;
  bool _reportedUsbPluginUnavailable = false;

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
  static const bool hasExplicitDesktopSerialPort = bool.hasEnvironment(
    'DESKTOP_SERIAL_PORT',
  );

  SerialPort? _desktopPort;
  StreamSubscription<Uint8List>? _desktopSubscription;

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

  @override
  String get sourceLabel => 'usb';

  @override
  bool get isOpen => _port != null || _desktopPort != null;

  @override
  void write(Uint8List bytes) {
    if (_port != null) {
      _port!.write(bytes);
    } else if (_desktopPort != null) {
      _desktopPort!.write(bytes);
    }
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _desktopSubscription?.cancel();
    _desktopSubscription = null;
    final port = _port;
    _port = null;
    await port?.close();
    final desktopPort = _desktopPort;
    _desktopPort = null;
    desktopPort?.close();
  }

  @override
  Future<bool> tryConnect() async {
    if (isOpen) {
      return true;
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
        return _connectDesktopSerial();
      }

      debugLog.throttled('usb_list_error', 'USB device list error: $e');
      return false;
    }

    if (devices.isEmpty) {
      if (_usbPluginUnavailable) {
        return _connectDesktopSerial();
      }
      debugLog.throttled('no_usb_devices', 'No USB devices found; retrying...');
      return false;
    }

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
          debugLog.throttled(
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
      debugLog.info('Found USB device: ${_describeUsbDevice(espDevice)}');
      final port = await espDevice.create();

      if (port == null) return false;

      bool openResult = await port.open();
      if (!openResult) {
        debugLog.throttled(
          'usb_open_failed',
          'Failed to open USB device '
              '${espDevice.vid?.toRadixString(16)}:${espDevice.pid?.toRadixString(16)}',
        );
        return false;
      }
      _port = port;

      await port.setDTR(true);
      await port.setRTS(true);
      // For CDC-ACM (ESP32-C3 USB Serial/JTAG), baud rate is
      // informational only — data moves at USB speed. Classic UART
      // bridges (CP210x/CH340/FTDI) need firmware-matching baud, set in
      // Config -> Connectivity (persisted).
      await port.setPortParameters(
        state.usbBaudRate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      debugLog.info(
        'USB port open: ${espDevice.deviceName} '
        '(${espDevice.vid?.toRadixString(16)}:${espDevice.pid?.toRadixString(16)} '
        '${espDevice.productName ?? ''})',
      );

      _subscription = port.inputStream?.listen(
        onBytes,
        onDone: () {
          _handleDisconnect();
        },
        onError: (e) {
          _handleDisconnect();
        },
      );
      return true;
    } catch (e) {
      // e.g. the user denied the USB permission dialog — retry later via
      // the reconnect timer instead of surfacing an unhandled error.
      debugLog.throttled('usb_open_error', 'USB open failed: $e');
      await _port?.close();
      _port = null;
      return false;
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
  @override
  Future<List<UsbPortOption>> listOptions() async {
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
    return [for (final port in ports) UsbPortOption(id: port, label: port)];
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

  Future<bool> _connectDesktopSerial() async {
    if (_desktopPort != null) {
      return true;
    }

    final candidates = _candidateDesktopPorts();
    if (candidates.isEmpty) {
      debugLog.throttled(
        'no_serial_ports',
        'No desktop serial ports available; retrying...',
      );
      return false;
    }

    final explicit = hasExplicitDesktopSerialPort
        ? ' (explicit --dart-define)'
        : ' (auto-detected)';
    debugLog.throttled(
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
        // firmware (115200 typical). Configurable in Config -> Connectivity.
        final config = port.config;
        config.baudRate = state.usbBaudRate;
        port.config = config;

        _desktopPort = port;
        debugLog.info(
          'Opened serial port $portName @ ${state.usbBaudRate} baud',
        );

        _desktopSubscription = SerialPortReader(port).stream.listen(
          onBytes,
          onDone: _handleDesktopDisconnect,
          onError: (Object e) {
            debugLog.error('Serial stream error on $portName: $e');
            _handleDesktopDisconnect();
          },
        );
        return true;
      } catch (e) {
        debugLog.warn('Serial connect error on $portName: $e');
        _desktopPort?.close();
        _desktopPort = null;
      }
    }

    debugLog.throttled(
      'serial_all_failed',
      'All serial candidates failed; retrying...',
    );
    return false;
  }

  void _handleDesktopDisconnect() {
    if (_desktopPort == null) {
      return;
    }
    _desktopSubscription?.cancel();
    _desktopSubscription = null;
    _desktopPort?.close();
    _desktopPort = null;
    onDisconnected('Desktop serial port disconnected');
  }

  void _handleDisconnect() {
    if (_port == null) {
      return;
    }
    _port?.close();
    _port = null;
    _subscription?.cancel();
    _subscription = null;
    onDisconnected('USB device disconnected');
  }
}
