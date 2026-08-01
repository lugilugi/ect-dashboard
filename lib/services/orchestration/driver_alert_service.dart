import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:telemetry_dashboard/models/alerts/driver_alert_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

abstract class DriverAlertOutput {
  Future<void> playAudio({
    required DriverAlertSeverity severity,
    required double volume,
    AlertCue cue = AlertCue.beep,
  });

  Future<void> playHaptic({required DriverAlertSeverity severity});
}

class PlatformDriverAlertOutput implements DriverAlertOutput {
  @override
  Future<void> playAudio({
    required DriverAlertSeverity severity,
    required double volume,
    AlertCue cue = AlertCue.beep,
  }) async {
    try {
      switch (cue) {
        case AlertCue.beep:
          await SystemSound.play(SystemSoundType.click);
          break;
        case AlertCue.doubleBeep:
        case AlertCue.tripleBeep:
        case AlertCue.longBeep:
        case AlertCue.siren:
          await SystemSound.play(SystemSoundType.alert);
          break;
      }
    } on PlatformException catch (e) {
      debugPrint('Driver alert audio failed: ${e.message}');
    }
  }

  @override
  Future<void> playHaptic({required DriverAlertSeverity severity}) async {
    try {
      switch (severity) {
        case DriverAlertSeverity.advisory:
          await HapticFeedback.selectionClick();
          break;
        case DriverAlertSeverity.warning:
          await HapticFeedback.mediumImpact();
          break;
        case DriverAlertSeverity.critical:
          await HapticFeedback.heavyImpact();
          break;
      }
    } on PlatformException catch (e) {
      debugPrint('Driver alert haptic failed: ${e.message}');
    }
  }
}

/// Android cue output backed by a native MethodChannel.
///
/// Flutter's [SystemSound] is a no-op on Android, so audio cues are produced
/// by a ToneGenerator on the platform side; haptics use the Vibrator with
/// severity-specific patterns.
class AndroidAlertOutput implements DriverAlertOutput {
  static const MethodChannel _channel = MethodChannel('ect_dashboard/alert_cue');

  @override
  Future<void> playAudio({
    required DriverAlertSeverity severity,
    required double volume,
    AlertCue cue = AlertCue.beep,
  }) async {
    try {
      await _channel.invokeMethod<void>('playAudio', <String, Object?>{
        'severity': severity.wireValue,
        'volume': volume.clamp(0.0, 1.0),
        'cue': cue.wireValue,
      });
    } on PlatformException catch (e) {
      debugPrint('Android alert audio failed: ${e.message}');
    } on MissingPluginException catch (e) {
      debugPrint('Android alert audio unavailable: ${e.message}');
    }
  }

  @override
  Future<void> playHaptic({required DriverAlertSeverity severity}) async {
    try {
      await _channel.invokeMethod<void>('playHaptic', <String, Object?>{
        'severity': severity.wireValue,
      });
    } on PlatformException catch (e) {
      debugPrint('Android alert haptic failed: ${e.message}');
    } on MissingPluginException catch (e) {
      debugPrint('Android alert haptic unavailable: ${e.message}');
    }
  }
}

class DriverAlertService {
  final DashboardState _state;
  final DriverAlertOutput _output;
  final DateTime Function() _nowProvider;

  bool _running = false;
  bool _isEvaluating = false;
  _AlertSnapshot? _snapshot;

  final Map<String, DateTime> _lastAlertAtByCode = <String, DateTime>{};
  final Map<String, bool> _activeVariableViolations = <String, bool>{};
  Timer? _criticalRepeatTimer;

  DriverAlertService({
    required DashboardState state,
    DriverAlertOutput? output,
    DateTime Function()? nowProvider,
  }) : _state = state,
       _output = output ?? _defaultOutput(),
       _nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  static DriverAlertOutput _defaultOutput() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidAlertOutput();
    }
    return PlatformDriverAlertOutput();
  }

  void start() {
    if (_running) {
      return;
    }

    _running = true;
    _snapshot = _AlertSnapshot.fromState(_state);
    _state.alerts.onRequestAlertTestTone = playTestTone;
    _state.addListener(_handleStateChanged);
  }

  void stop() {
    if (!_running) {
      return;
    }

    _running = false;
    _criticalRepeatTimer?.cancel();
    _criticalRepeatTimer = null;
    _state.removeListener(_handleStateChanged);
    _state.alerts.onRequestAlertTestTone = null;
  }

  Future<void> playTestTone() {
    return _emitAlert(
      alertCode: 'manual_test_tone',
      severity: DriverAlertSeverity.warning,
      reasonClass: 'MANUAL_TEST',
      allowCooldown: false,
      allowCriticalRepeat: false,
    );
  }

  void _handleStateChanged() {
    if (!_running || _isEvaluating) {
      return;
    }

    _isEvaluating = true;
    try {
      final previous = _snapshot ?? _AlertSnapshot.fromState(_state);
      final next = _AlertSnapshot.fromState(_state);

      if (next.isLogging) {
        _handleConnectivity(previous: previous, next: next);
        _handleFaults(previous: previous, next: next);
        _handleLapEvents(previous: previous, next: next);
        _handleVariables();
      } else {
        _activeVariableViolations.clear();
      }

      _snapshot = next;
    } finally {
      _isEvaluating = false;
    }
  }

  void _handleConnectivity({
    required _AlertSnapshot previous,
    required _AlertSnapshot next,
  }) {
    final hadAnyLink = previous.usbConnected || previous.mqttConnected;
    final hasAnyLink = next.usbConnected || next.mqttConnected;

    if (hadAnyLink && !hasAnyLink) {
      unawaited(
        _emitAlert(
          alertCode: 'telemetry_disconnect_blackout',
          severity: DriverAlertSeverity.critical,
          reasonClass: 'TELEMETRY_BLACKOUT',
        ),
      );
      return;
    }

    if (previous.usbConnected && !next.usbConnected) {
      unawaited(
        _emitAlert(
          alertCode: 'telemetry_disconnect_usb',
          severity: DriverAlertSeverity.warning,
          reasonClass: 'USB_LINK',
        ),
      );
    }

    if (previous.mqttConnected && !next.mqttConnected) {
      unawaited(
        _emitAlert(
          alertCode: 'telemetry_disconnect_mqtt',
          severity: DriverAlertSeverity.warning,
          reasonClass: 'MQTT_LINK',
        ),
      );
    }
  }

  void _handleFaults({
    required _AlertSnapshot previous,
    required _AlertSnapshot next,
  }) {
    final previousClass = _resolveCriticalFaultClass(previous);
    final nextClass = _resolveCriticalFaultClass(next);

    if (nextClass == null || nextClass == previousClass) {
      return;
    }

    unawaited(
      _emitAlert(
        alertCode: 'critical_fault_$nextClass',
        severity: DriverAlertSeverity.critical,
        reasonClass: nextClass,
      ),
    );
  }

  void _handleLapEvents({
    required _AlertSnapshot previous,
    required _AlertSnapshot next,
  }) {
    if (next.lapsCompleted > previous.lapsCompleted) {
      unawaited(
        _emitAlert(
          alertCode: 'lap_accepted',
          severity: DriverAlertSeverity.advisory,
          reasonClass: 'LAP_ACCEPTED',
          allowCriticalRepeat: false,
        ),
      );
    }

    if (next.lastCrossingReason != null &&
        next.lastCrossingReason != previous.lastCrossingReason) {
      final reasonClass = _classifyCrossingReason(next.lastCrossingReason!);
      unawaited(
        _emitAlert(
          alertCode: 'lap_rejected_$reasonClass',
          severity: DriverAlertSeverity.warning,
          reasonClass: reasonClass,
          allowCriticalRepeat: false,
        ),
      );
    }
  }

  String? _resolveCriticalFaultClass(_AlertSnapshot snapshot) {
    if (snapshot.lastErrorCode != 'OK') {
      return _classifyErrorCode(snapshot.lastErrorCode);
    }

    if (snapshot.mcFaultSignature != 'NONE') {
      return 'MC_FAULT';
    }

    if (snapshot.errorCount > 0) {
      return 'GENERIC_FAULT';
    }

    return null;
  }

  String _classifyErrorCode(String code) {
    final normalized = code.toUpperCase();
    if (normalized.contains('THERM') || normalized.contains('TEMP')) {
      return 'THERMAL';
    }
    if (normalized.contains('BMS') || normalized.contains('CELL')) {
      return 'BMS';
    }
    if (normalized.contains('POWER') ||
        normalized.contains('VOLT') ||
        normalized.contains('CURR')) {
      return 'POWERTRAIN';
    }
    if (normalized.contains('CAN') ||
        normalized.contains('BUS') ||
        normalized.contains('USB')) {
      return 'LINK';
    }
    return 'CRITICAL';
  }

  String _classifyCrossingReason(String reason) {
    final normalized = reason.toLowerCase();
    if (normalized.contains('speed')) {
      return 'CROSS_SPEED';
    }
    if (normalized.contains('heading')) {
      return 'CROSS_HEADING';
    }
    if (normalized.contains('lap_time')) {
      return 'CROSS_TIMING';
    }
    return 'CROSS_FILTER';
  }

  void _handleVariables() {
    for (final spec in alertVariableSpecs) {
      final settings = _state.alertVariables[spec.key];
      if (settings == null || !settings.enabled) {
        _activeVariableViolations['${spec.key.wireValue}_MIN'] = false;
        _activeVariableViolations['${spec.key.wireValue}_MAX'] = false;
        continue;
      }

      final value = _state.alertVariableValue(spec.key);
      final minKey = '${spec.key.wireValue}_MIN';
      final maxKey = '${spec.key.wireValue}_MAX';

      if (value == spec.restValue) {
        _activeVariableViolations[minKey] = false;
        _activeVariableViolations[maxKey] = false;
        continue;
      }

      if (value < settings.minThreshold) {
        if (_activeVariableViolations[minKey] != true) {
          _activeVariableViolations[minKey] = true;
          _activeVariableViolations[maxKey] = false;
          unawaited(
            _emitAlert(
              alertCode: 'var_${spec.key.wireValue.toLowerCase()}_min',
              severity: spec.severity,
              reasonClass: 'VAR_$minKey',
              cue: settings.cue,
            ),
          );
        }
      } else if (value > settings.maxThreshold) {
        if (_activeVariableViolations[maxKey] != true) {
          _activeVariableViolations[minKey] = false;
          _activeVariableViolations[maxKey] = true;
          unawaited(
            _emitAlert(
              alertCode: 'var_${spec.key.wireValue.toLowerCase()}_max',
              severity: spec.severity,
              reasonClass: 'VAR_$maxKey',
              cue: settings.cue,
            ),
          );
        }
      } else {
        _activeVariableViolations[minKey] = false;
        _activeVariableViolations[maxKey] = false;
      }
    }
  }

  Future<void> _emitAlert({
    required String alertCode,
    required DriverAlertSeverity severity,
    required String reasonClass,
    AlertCue cue = AlertCue.beep,
    bool allowCooldown = true,
    bool allowCriticalRepeat = true,
  }) async {
    final nowUtc = _nowProvider().toUtc();
    if (!_channelEnabledForSeverity(severity)) {
      return;
    }
    if (allowCooldown && _isWithinCooldown(alertCode: alertCode, nowUtc: nowUtc)) {
      return;
    }

    _lastAlertAtByCode[alertCode] = nowUtc;

    await _playCue(severity: severity, cue: cue);
    _state.recordAlertEmission(
      alertCode: alertCode,
      severity: severity,
      reasonClass: reasonClass,
      atUtc: nowUtc,
    );

    if (allowCriticalRepeat && severity == DriverAlertSeverity.critical) {
      _scheduleCriticalRepeats();
    }
  }

  bool _channelEnabledForSeverity(DriverAlertSeverity severity) {
    if (!_state.alertAudioEnabled && !_state.alertHapticsEnabled) {
      return false;
    }

    if (severity == DriverAlertSeverity.advisory &&
        !_state.alertAdvisoryEnabled) {
      return false;
    }

    return true;
  }

  bool _isWithinCooldown({
    required String alertCode,
    required DateTime nowUtc,
  }) {
    final cooldownMs = _state.alertCooldownMs.clamp(0, 10000);
    if (cooldownMs <= 0) {
      return false;
    }

    final previous = _lastAlertAtByCode[alertCode];
    if (previous == null) {
      return false;
    }

    return nowUtc.difference(previous).inMilliseconds < cooldownMs;
  }

  Future<void> _playCue({
    required DriverAlertSeverity severity,
    AlertCue cue = AlertCue.beep,
  }) async {
    if (_state.alertAudioEnabled) {
      await _output.playAudio(severity: severity, volume: _state.alertVolume, cue: cue);
    }

    if (_state.alertHapticsEnabled) {
      await _output.playHaptic(severity: severity);
    }
  }

  void _scheduleCriticalRepeats() {
    _criticalRepeatTimer?.cancel();
    final repeatCount = _state.alertCriticalRepeatCount.clamp(0, 6);
    if (repeatCount <= 0) {
      return;
    }

    final intervalMs = _state.alertCriticalRepeatIntervalMs.clamp(150, 5000);
    int remaining = repeatCount;

    _criticalRepeatTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (timer) async {
        if (!_running || remaining <= 0) {
          timer.cancel();
          return;
        }

        remaining -= 1;
        await _playCue(severity: DriverAlertSeverity.critical);
        if (remaining <= 0) {
          timer.cancel();
        }
      },
    );
  }
}

class _AlertSnapshot {
  final bool isLogging;
  final bool usbConnected;
  final bool mqttConnected;
  final int lapsCompleted;
  final String? lastCrossingReason;
  final int errorCount;
  final String lastErrorCode;
  final String mcFaultSignature;

  const _AlertSnapshot({
    required this.isLogging,
    required this.usbConnected,
    required this.mqttConnected,
    required this.lapsCompleted,
    required this.lastCrossingReason,
    required this.errorCount,
    required this.lastErrorCode,
    required this.mcFaultSignature,
  });

  factory _AlertSnapshot.fromState(DashboardState state) {
    final mcSignature = state.mcFaults.isEmpty
        ? 'NONE'
        : state.mcFaults.join('|').toUpperCase();

    return _AlertSnapshot(
      isLogging: state.isLogging,
      usbConnected: state.isConnected,
      mqttConnected: state.isServerConnected,
      lapsCompleted: state.lapsCompleted,
      lastCrossingReason: state.lastCrossingReason,
      errorCount: state.errorCount,
      lastErrorCode: state.lastErrorCode.toUpperCase(),
      mcFaultSignature: mcSignature,
    );
  }
}
