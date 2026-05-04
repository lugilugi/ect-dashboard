import 'package:shared_preferences/shared_preferences.dart';

import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

class AppPreferencesService {
  static const String _kMqttHost = 'prefs.mqtt_host';
  static const String _kUseLightTheme = 'prefs.use_light_theme';
  static const String _kUseDictionaryAuxDispatch =
      'prefs.use_dictionary_aux_dispatch';
  static const String _kLapsPlanned = 'prefs.laps_planned';
  static const String _kCrossingDeadzoneMs = 'prefs.crossing_deadzone_ms';
  static const String _kLapDividerMode = 'prefs.lap_divider_mode';
  static const String _kDistanceLapDividerKm = 'prefs.distance_lap_divider_km';
  static const String _kGpsFallbackPeriodMs = 'prefs.gps_fallback_period_ms';
  static const String _kReadableCopyRetentionDays =
      'prefs.readable_copy_retention_days';
  static const String _kReadableCopyMaxFileBytes =
      'prefs.readable_copy_max_file_bytes';
  static const String _kAlertAudioEnabled = 'prefs.alert_audio_enabled';
  static const String _kAlertHapticsEnabled = 'prefs.alert_haptics_enabled';
  static const String _kAlertAdvisoryEnabled = 'prefs.alert_advisory_enabled';
  static const String _kAlertVolume = 'prefs.alert_volume';
  static const String _kAlertCooldownMs = 'prefs.alert_cooldown_ms';
  static const String _kAlertCriticalRepeatCount =
      'prefs.alert_critical_repeat_count';
  static const String _kAlertCriticalRepeatIntervalMs =
      'prefs.alert_critical_repeat_interval_ms';

  String buildStateSignature(DashboardState state) {
    return <Object?>[
      state.mqttHost,
      state.useLightTheme,
      state.useDictionaryAuxDispatch,
      state.lapsPlanned,
      state.crossingDeadzoneMs,
      state.lapDividerMode.wireValue,
      state.distanceLapDividerKm.toStringAsFixed(3),
      state.gpsFallbackPeriodMs,
      state.readableCopyRetentionDays,
      state.readableCopyMaxFileBytes,
      state.alertAudioEnabled,
      state.alertHapticsEnabled,
      state.alertAdvisoryEnabled,
      state.alertVolume.toStringAsFixed(3),
      state.alertCooldownMs,
      state.alertCriticalRepeatCount,
      state.alertCriticalRepeatIntervalMs,
    ].join('|');
  }

  Future<void> restoreIntoState(DashboardState state) async {
    final prefs = await SharedPreferences.getInstance();

    final host = prefs.getString(_kMqttHost);
    if (host != null && host.isNotEmpty) {
      state.updateMqttHost(host);
    }

    final useLightTheme = prefs.getBool(_kUseLightTheme);
    if (useLightTheme != null) {
      state.toggleTheme(useLightTheme);
    }

    final useDictionaryAuxDispatch = prefs.getBool(_kUseDictionaryAuxDispatch);
    if (useDictionaryAuxDispatch != null) {
      state.toggleDictionaryAuxDispatch(useDictionaryAuxDispatch);
    }

    final lapsPlanned = prefs.getInt(_kLapsPlanned);
    if (lapsPlanned != null) {
      state.setLapsPlanned(lapsPlanned);
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

    final alertAudioEnabled = prefs.getBool(_kAlertAudioEnabled);
    if (alertAudioEnabled != null) {
      state.setAlertAudioEnabled(alertAudioEnabled);
    }

    final alertHapticsEnabled = prefs.getBool(_kAlertHapticsEnabled);
    if (alertHapticsEnabled != null) {
      state.setAlertHapticsEnabled(alertHapticsEnabled);
    }

    final alertAdvisoryEnabled = prefs.getBool(_kAlertAdvisoryEnabled);
    if (alertAdvisoryEnabled != null) {
      state.setAlertAdvisoryEnabled(alertAdvisoryEnabled);
    }

    final alertVolume = prefs.getDouble(_kAlertVolume);
    if (alertVolume != null) {
      state.setAlertVolume(alertVolume);
    }

    final alertCooldownMs = prefs.getInt(_kAlertCooldownMs);
    if (alertCooldownMs != null) {
      state.setAlertCooldownMs(alertCooldownMs);
    }

    final alertCriticalRepeatCount = prefs.getInt(_kAlertCriticalRepeatCount);
    if (alertCriticalRepeatCount != null) {
      state.setAlertCriticalRepeatCount(alertCriticalRepeatCount);
    }

    final alertCriticalRepeatIntervalMs = prefs.getInt(
      _kAlertCriticalRepeatIntervalMs,
    );
    if (alertCriticalRepeatIntervalMs != null) {
      state.setAlertCriticalRepeatIntervalMs(alertCriticalRepeatIntervalMs);
    }
  }

  Future<void> saveFromState(DashboardState state) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_kMqttHost, state.mqttHost);
    await prefs.setBool(_kUseLightTheme, state.useLightTheme);
    await prefs.setBool(
      _kUseDictionaryAuxDispatch,
      state.useDictionaryAuxDispatch,
    );
    await prefs.setInt(_kLapsPlanned, state.lapsPlanned);
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
    await prefs.setBool(_kAlertAudioEnabled, state.alertAudioEnabled);
    await prefs.setBool(_kAlertHapticsEnabled, state.alertHapticsEnabled);
    await prefs.setBool(_kAlertAdvisoryEnabled, state.alertAdvisoryEnabled);
    await prefs.setDouble(_kAlertVolume, state.alertVolume);
    await prefs.setInt(_kAlertCooldownMs, state.alertCooldownMs);
    await prefs.setInt(
      _kAlertCriticalRepeatCount,
      state.alertCriticalRepeatCount,
    );
    await prefs.setInt(
      _kAlertCriticalRepeatIntervalMs,
      state.alertCriticalRepeatIntervalMs,
    );
  }
}
