import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:telemetry_dashboard/models/telemetry/phone_gps_sample.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/services/location/android_foreground_telemetry_service.dart';
import 'package:telemetry_dashboard/services/persistence/app_preferences_service.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/ingest/command_dictionary_service.dart';
import 'package:telemetry_dashboard/services/orchestration/driver_alert_service.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';
import 'package:telemetry_dashboard/services/location/phone_gps_fallback_service.dart';
import 'package:telemetry_dashboard/services/orchestration/session_checkpoint_service.dart';
import 'package:telemetry_dashboard/services/ingest/usb_service.dart';

class TelemetryRuntimeCoordinator {
  final DashboardState state;
  final CanIngestRepository canIngestRepository;
  final AppPreferencesService _appPreferencesService;
  final AndroidForegroundTelemetryService _foregroundTelemetryService;

  Timer? _preferenceSaveDebounce;
  bool _preferencesLoaded = false;
  String? _lastPreferenceSignature;
  SessionState? _lastObservedSessionState;
  bool _foregroundServiceRunning = false;
  bool _wakelockHeld = false;
  bool _servicesStarted = false;
  bool _initialized = false;
  bool _disposed = false;

  late CommandDictionaryService _commandDictionaryService;
  late CanTxService _canTxService;
  late LocalSpoolService _localSpoolService;
  late UsbService _usbService;
  late MqttService _mqttService;
  late GpsSourceManager _gpsSourceManager;
  DriverAlertService? _driverAlertService;
  PhoneGpsFallbackService? _phoneGpsFallbackService;
  SessionCheckpointService? _sessionCheckpointService;

  TelemetryRuntimeCoordinator({
    required this.state,
    required this.canIngestRepository,
    AppPreferencesService? appPreferencesService,
    AndroidForegroundTelemetryService? foregroundTelemetryService,
  }) : _appPreferencesService =
           appPreferencesService ?? AppPreferencesService(),
       _foregroundTelemetryService =
           foregroundTelemetryService ?? AndroidForegroundTelemetryService();

  Future<void> start() async {
    if (_disposed) {
      return;
    }

    _initializeRuntime();
    await _startRuntimeServices();
  }

  void dispose() {
    if (!_initialized || _disposed) {
      return;
    }

    _disposed = true;
    state.removeListener(_handleStateChanged);
    state.removeListener(_handleStatePreferenceSync);
    state.onRequestReadableCopyPreview = null;
    state.onRequestReadableCopyExport = null;
    state.onReadableCopyRetentionDaysChanged = null;
    state.onReadableCopyMaxFileBytesChanged = null;
    state.onSimulationToggleChanged = null;
    state.onRequestMqttSpoolReset = null;
    state.onRequestLocalStorageClear = null;
    _driverAlertService?.stop();
    if (_foregroundServiceRunning) {
      unawaited(_foregroundTelemetryService.stop());
      _foregroundServiceRunning = false;
    }
    _phoneGpsFallbackService?.stop();
    _sessionCheckpointService?.stop();
    _preferenceSaveDebounce?.cancel();
    _setWakelock(false);
    _canTxService.dispose();
    _usbService.stop();
    // Drain the final canonical flush (publish or spool) before closing the
    // SQLite database so no last-second payload is lost on app exit.
    unawaited(
      _mqttService.stop().whenComplete(() => _localSpoolService.close()),
    );
  }

  void _initializeRuntime() {
    if (_initialized || _disposed) {
      return;
    }

    _localSpoolService = LocalSpoolService(
      readableCopyMaxFileBytes: state.readableCopyMaxFileBytes,
    );
    state.attachSpoolHealthStore(_localSpoolService.spoolHealth);

    state.onRequestReadableCopyPreview = () {
      return _localSpoolService.readReadableCopyPreview(
        maxFiles: 6,
        maxLinesPerFile: 8,
        maxLineLength: 220,
      );
    };
    state.onRequestReadableCopyExport = () {
      return _localSpoolService.exportReadableCopy();
    };
    state.onReadableCopyRetentionDaysChanged = (retentionDays) {
      return _localSpoolService.pruneReadableCopyOlderThan(
        Duration(days: retentionDays),
      );
    };
    state.onReadableCopyMaxFileBytesChanged = (maxFileBytes) {
      return _localSpoolService.setReadableCopyMaxFileBytes(maxFileBytes);
    };

    _mqttService = MqttService(state, localSpoolService: _localSpoolService);
    _driverAlertService = DriverAlertService(state: state);
    _driverAlertService!.start();

    _gpsSourceManager = GpsSourceManager(
      state,
      onPhoneFallbackSample: _publishPhoneFallbackTelemetry,
    );

    _commandDictionaryService = CommandDictionaryService();
    _canTxService = CanTxService(
      dictionaryService: _commandDictionaryService,
      sendRawFrame: (frame) {
        _usbService.sendString(frame);
      },
      onResult: state.recordCanTxResult,
      isDriverMode: () => state.uiMode == UiMode.driver,
      isLogging: () => state.isLogging,
    );
    state.onTxCommand = _canTxService.sendCommand;

    final shouldStartPhoneFallback =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (shouldStartPhoneFallback) {
      _phoneGpsFallbackService = PhoneGpsFallbackService(
        state,
        _gpsSourceManager,
      );
    }

    _usbService = UsbService(
      state,
      _mqttService,
      _gpsSourceManager,
      _canTxService,
      _localSpoolService,
      canIngestRepository,
    );
    state.attachUsbDebugLogStore(_usbService.debugLog);
    state.onUsbTx = _usbService.sendString;
    state.onRequestUsbPortOptions = _usbService.listPortOptions;
    state.onUsbPortSelectionChanged = _usbService.applyPortSelection;
    state.onSimulationToggleChanged = _usbService.setSimulationEnabled;
    state.onRequestMqttSpoolReset = () => _mqttService.resetSpool();
    state.onRequestLocalStorageClear = () => _localSpoolService.clearAllLocalStorage();

    state.addListener(_handleStateChanged);
    state.addListener(_handleStatePreferenceSync);
    _handleStateChanged();

    _initialized = true;
  }

  void _publishPhoneFallbackTelemetry(PhoneGpsSample sample) {
    _mqttService.publish(
      'GPS_Latitude_Deg',
      sample.latitude,
      source: 'phone_gps',
      unit: 'deg',
    );
    _mqttService.publish(
      'GPS_Longitude_Deg',
      sample.longitude,
      source: 'phone_gps',
      unit: 'deg',
    );
    _mqttService.publish(
      'GPS_Speed_Kmh',
      sample.speedKmh,
      source: 'phone_gps',
      unit: 'km/h',
    );
    _mqttService.publish(
      'GPS_Heading_Deg',
      sample.headingDeg.isNaN ? 0.0 : sample.headingDeg,
      source: 'phone_gps',
      unit: 'deg',
    );
    _mqttService.publish(
      'GPS_Accuracy_M',
      sample.accuracyM,
      source: 'phone_gps',
      unit: 'm',
    );
    _mqttService.publish(
      'GPS_Locked',
      sample.locked ? 1.0 : 0.0,
      source: 'phone_gps',
      unit: 'bool',
    );
    _mqttService.publish(
      'GPS_Fallback_Active',
      1.0,
      source: 'phone_gps',
      unit: 'bool',
    );
    _mqttService.publish(
      'GPS_Fallback_Period_Ms',
      state.gpsFallbackPeriodMs.toDouble(),
      source: 'phone_gps',
      unit: 'ms',
    );
  }

  Future<void> _startRuntimeServices() async {
    if (_disposed || _servicesStarted) {
      return;
    }

    if (!_preferencesLoaded) {
      await _appPreferencesService.restoreIntoState(state);
      _preferencesLoaded = true;
      _lastPreferenceSignature = _appPreferencesService.buildStateSignature(
        state,
      );
      _handleStateChanged();
    }

    _servicesStarted = true;
    _sessionCheckpointService ??= SessionCheckpointService(
      state: state,
      localSpoolService: _localSpoolService,
      mqttService: _mqttService,
    );
    await _sessionCheckpointService!.start();
    if (_disposed) {
      return;
    }

    await _mqttService.start();
    if (_disposed) {
      return;
    }

    state.setReadableCopyDirectoryPath(
      _localSpoolService.sessionCsvPath ?? _localSpoolService.readableCopyPath,
    );
    await state.refreshReadableCopyPreview();
    unawaited(_phoneGpsFallbackService?.start());
    _usbService.start();
  }

  void _handleStatePreferenceSync() {
    if (_disposed || !_preferencesLoaded) {
      return;
    }

    final signature = _appPreferencesService.buildStateSignature(state);
    if (_lastPreferenceSignature == signature) {
      return;
    }

    _lastPreferenceSignature = signature;
    _preferenceSaveDebounce?.cancel();
    _preferenceSaveDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_appPreferencesService.saveFromState(state));
    });
  }

  void _setWakelock(bool enabled) {
    if (_wakelockHeld == enabled) {
      return;
    }

    _wakelockHeld = enabled;
    unawaited(WakelockPlus.toggle(enable: enabled));
  }

  void _handleStateChanged() {
    if (_disposed) {
      return;
    }

    final sessionState = state.sessionState;
    final shouldRunForegroundService =
        sessionState == SessionState.armed ||
        sessionState == SessionState.logging;

    _setWakelock(shouldRunForegroundService);

    if (_lastObservedSessionState == sessionState) {
      return;
    }
    _lastObservedSessionState = sessionState;

    if (shouldRunForegroundService == _foregroundServiceRunning) {
      return;
    }

    _foregroundServiceRunning = shouldRunForegroundService;
    if (shouldRunForegroundService) {
      unawaited(
        _foregroundTelemetryService.start(
          title: 'ECT Telemetry Active',
          text: state.sessionName.isEmpty
              ? 'Session is active.'
              : 'Session: ${state.sessionName}',
        ),
      );
      return;
    }

    unawaited(_foregroundTelemetryService.stop());
  }
}
