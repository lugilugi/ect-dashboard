
import 'package:shared_preferences/shared_preferences.dart';

import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/ingest/ingest_transport.dart';

class AppPreferencesService {
  static const String _kMqttHost = 'prefs.mqtt_host';
  static const String _kMqttPort = 'prefs.mqtt_port';
  static const String _kUsbPortSelection = 'prefs.usb_port_selection';
  static const String _kUsbBaudRate = 'prefs.usb_baud_rate';
  static const String _kLinkMode = 'prefs.link_mode';
  static const String _kBleDeviceSelection = 'prefs.ble_device_selection';
  static const String _kUseLightTheme = 'prefs.use_light_theme';
  static const String _kUseDictionaryAuxDispatch =
      'prefs.use_dictionary_aux_dispatch';

  static const String _kCrossingDeadzoneMs = 'prefs.crossing_deadzone_ms';
  static const String _kLapDividerMode = 'prefs.lap_divider_mode';
  static const String _kDistanceLapDividerKm = 'prefs.distance_lap_divider_km';
  static const String _kGpsFallbackPeriodMs = 'prefs.gps_fallback_period_ms';
  static const String _kReadableCopyRetentionDays =
      'prefs.readable_copy_retention_days';
  static const String _kReadableCopyMaxFileBytes =
      'prefs.readable_copy_max_file_bytes';
  // Driver alerts were removed; these keys are cleared once on restore.
  static const List<String> _retiredKeys = <String>[
    'prefs.alert_audio_enabled',
    'prefs.alert_haptics_enabled',
    'prefs.alert_advisory_enabled',
    'prefs.alert_volume',
    'prefs.alert_cooldown_ms',
    'prefs.alert_critical_repeat_count',
    'prefs.alert_critical_repeat_interval_ms',
    'prefs.alert_variables',
  ];
  static const String _kLastKnownLat = 'prefs.last_known_lat';
  static const String _kLastKnownLon = 'prefs.last_known_lon';

  String buildStateSignature(DashboardState state) {
    return <Object?>[
      state.mqttHost,
      state.mqttPort,
      state.usbPortSelection,
      state.usbBaudRate,
      state.linkMode.name,
      state.bleDeviceSelection,
      state.useLightTheme,
      state.useDictionaryAuxDispatch,
      state.crossingDeadzoneMs,
      state.lapDividerMode.wireValue,
      state.distanceLapDividerKm.toStringAsFixed(3),
      state.gpsFallbackPeriodMs,
      state.readableCopyRetentionDays,
      state.readableCopyMaxFileBytes,
    ].join('|');
  }

  Future<void> restoreIntoState(DashboardState state) async {
    final prefs = await SharedPreferences.getInstance();

    final host = prefs.getString(_kMqttHost);
    if (host != null && host.isNotEmpty) {
      state.updateMqttHost(host);
    }

    final mqttPort = prefs.getInt(_kMqttPort);
    if (mqttPort != null) {
      state.updateMqttPort(mqttPort);
    }

    final usbPortSelection = prefs.getString(_kUsbPortSelection);
    if (usbPortSelection != null && usbPortSelection.isNotEmpty) {
      state.updateUsbPortSelection(usbPortSelection);
    }

    final usbBaudRate = prefs.getInt(_kUsbBaudRate);
    if (usbBaudRate != null && usbBaudRate > 0) {
      state.updateUsbBaudRate(usbBaudRate);
    }

    final bleDeviceSelection = prefs.getString(_kBleDeviceSelection);
    if (bleDeviceSelection != null && bleDeviceSelection.isNotEmpty) {
      state.updateBleDeviceSelection(bleDeviceSelection);
    }

    // Falls back to USB where BLE is unsupported (non-Android).
    state.updateLinkMode(LinkMode.fromWire(prefs.getString(_kLinkMode)));

    final useLightTheme = prefs.getBool(_kUseLightTheme);
    if (useLightTheme != null) {
      state.toggleTheme(useLightTheme);
    }

    final useDictionaryAuxDispatch = prefs.getBool(_kUseDictionaryAuxDispatch);
    if (useDictionaryAuxDispatch != null) {
      state.toggleDictionaryAuxDispatch(useDictionaryAuxDispatch);
    }


    final crossingDeadzoneMs = prefs.getInt(_kCrossingDeadzoneMs);
    if (crossingDeadzoneMs != null) {
      state.setCrossingDeadzoneMs(crossingDeadzoneMs);
    }

    final lapDividerMode = prefs.getString(_kLapDividerMode);
    if (lapDividerMode != null) {
      state.setLapDividerMode(LapDividerModeWire.fromWire(lapDividerMode));
    }

    final distanceLapDividerKm = prefs.getDouble(_kDistanceLapDividerKm);
    if (distanceLapDividerKm != null) {
      state.setDistanceLapDividerKm(distanceLapDividerKm);
    }

    final gpsFallbackPeriodMs = prefs.getInt(_kGpsFallbackPeriodMs);
    if (gpsFallbackPeriodMs != null) {
      state.setGpsFallbackPeriodMs(gpsFallbackPeriodMs);
    }

    final readableCopyRetentionDays = prefs.getInt(_kReadableCopyRetentionDays);
    if (readableCopyRetentionDays != null) {
      state.setReadableCopyRetentionDays(readableCopyRetentionDays);
    }

    final readableCopyMaxFileBytes = prefs.getInt(_kReadableCopyMaxFileBytes);
    if (readableCopyMaxFileBytes != null) {
      state.setReadableCopyMaxFileBytes(readableCopyMaxFileBytes);
    }

    for (final key in _retiredKeys) {
      if (prefs.containsKey(key)) {
        await prefs.remove(key);
      }
    }

    final lastLat = prefs.getDouble(_kLastKnownLat);
    final lastLon = prefs.getDouble(_kLastKnownLon);
    if (lastLat != null && lastLon != null) {
      state.lastKnownLat = lastLat;
      state.lastKnownLon = lastLon;
    }
  }

  Future<void> saveFromState(DashboardState state) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_kMqttHost, state.mqttHost);
    await prefs.setInt(_kMqttPort, state.mqttPort);
    await prefs.setString(_kUsbPortSelection, state.usbPortSelection);
    await prefs.setInt(_kUsbBaudRate, state.usbBaudRate);
    await prefs.setString(_kLinkMode, state.linkMode.name);
    await prefs.setString(_kBleDeviceSelection, state.bleDeviceSelection);
    await prefs.setBool(_kUseLightTheme, state.useLightTheme);
    await prefs.setBool(
      _kUseDictionaryAuxDispatch,
      state.useDictionaryAuxDispatch,
    );
    await prefs.setInt(_kCrossingDeadzoneMs, state.crossingDeadzoneMs);
    await prefs.setString(_kLapDividerMode, state.lapDividerMode.wireValue);
    await prefs.setDouble(_kDistanceLapDividerKm, state.distanceLapDividerKm);
    await prefs.setInt(_kGpsFallbackPeriodMs, state.gpsFallbackPeriodMs);
    await prefs.setInt(
      _kReadableCopyRetentionDays,
      state.readableCopyRetentionDays,
    );
    await prefs.setInt(
      _kReadableCopyMaxFileBytes,
      state.readableCopyMaxFileBytes,
    );
    if (state.lastKnownLat != null) {
      await prefs.setDouble(_kLastKnownLat, state.lastKnownLat!);
    }
    if (state.lastKnownLon != null) {
      await prefs.setDouble(_kLastKnownLon, state.lastKnownLon!);
    }
  }
}
