import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import 'models/session_models.dart';
import 'providers/dashboard_state.dart';
import 'services/android_foreground_telemetry_service.dart';
import 'services/can_tx_service.dart';
import 'services/command_dictionary_service.dart';
import 'services/gps_source_manager.dart';
import 'services/local_spool_service.dart';
import 'services/usb_service.dart';
import 'services/mqtt_service.dart';
import 'services/driver_alert_service.dart';
import 'services/phone_gps_fallback_service.dart';
import 'services/session_checkpoint_service.dart';
import 'ui/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]).then((_) {
    runApp(
      ChangeNotifierProvider(
        create: (context) => DashboardState(),
        child: const TelemetryApp(),
      ),
    );
  });
}

class TelemetryApp extends StatefulWidget {
  const TelemetryApp({super.key});

  @override
  State<TelemetryApp> createState() => _TelemetryAppState();
}

class _TelemetryAppState extends State<TelemetryApp> {
  late DashboardState _state;
  late CommandDictionaryService _commandDictionaryService;
  late CanTxService _canTxService;
  late LocalSpoolService _localSpoolService;
  late UsbService _usbService;
  late MqttService _mqttService;
  late GpsSourceManager _gpsSourceManager;
  DriverAlertService? _driverAlertService;
  PhoneGpsFallbackService? _phoneGpsFallbackService;
  SessionCheckpointService? _sessionCheckpointService;
  final AndroidForegroundTelemetryService _foregroundTelemetryService =
      AndroidForegroundTelemetryService();
  SessionState? _lastObservedSessionState;
  bool _foregroundServiceRunning = false;
  bool _servicesStarted = false;

  @override
  void initState() {
    super.initState();

    // Initialize USB Service and start listening
    _state = Provider.of<DashboardState>(context, listen: false);

    _localSpoolService = LocalSpoolService(
      readableCopyMaxFileBytes: _state.readableCopyMaxFileBytes,
    );

    _state.onRequestReadableCopyPreview = () {
      return _localSpoolService.readReadableCopyPreview(
        maxFiles: 6,
        maxLinesPerFile: 8,
        maxLineLength: 220,
      );
    };
    _state.onRequestReadableCopyExport = () {
      return _localSpoolService.exportReadableCopy();
    };
    _state.onReadableCopyRetentionDaysChanged = (retentionDays) {
      return _localSpoolService.pruneReadableCopyOlderThan(
        Duration(days: retentionDays),
      );
    };
    _state.onReadableCopyMaxFileBytesChanged = (maxFileBytes) {
      return _localSpoolService.setReadableCopyMaxFileBytes(maxFileBytes);
    };

    _mqttService = MqttService(_state, localSpoolService: _localSpoolService);
    _driverAlertService = DriverAlertService(state: _state);
    _driverAlertService!.start();

    _gpsSourceManager = GpsSourceManager(_state);

    _commandDictionaryService = CommandDictionaryService();
    _canTxService = CanTxService(
      dictionaryService: _commandDictionaryService,
      sendRawFrame: (frame) {
        _usbService.sendString(frame);
      },
      onResult: _state.recordCanTxResult,
      isDriverMode: () => _state.uiMode == UiMode.driver,
      isLogging: () => _state.isLogging,
    );
    _state.onTxCommand = _canTxService.sendCommand;

    final shouldStartPhoneFallback =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (shouldStartPhoneFallback) {
      _phoneGpsFallbackService = PhoneGpsFallbackService(
        _state,
        _gpsSourceManager,
      );
    }

    _usbService = UsbService(
      _state,
      _mqttService,
      _gpsSourceManager,
      _canTxService,
      _localSpoolService,
    );
    _state.onUsbTx = _usbService.sendString;
    _state.onSimulationToggleChanged = _usbService.setSimulationEnabled;

    _state.addListener(_handleStateChanged);
    _handleStateChanged();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startRuntimeServices());
    });
  }

  Future<void> _startRuntimeServices() async {
    if (!mounted || _servicesStarted) {
      return;
    }

    _servicesStarted = true;
    _sessionCheckpointService ??= SessionCheckpointService(
      state: _state,
      localSpoolService: _localSpoolService,
      mqttService: _mqttService,
    );
    await _sessionCheckpointService!.start();
    await _mqttService.start();
    _state.setReadableCopyDirectoryPath(
      _localSpoolService.sessionCsvPath ?? _localSpoolService.readableCopyPath,
    );
    await _state.refreshReadableCopyPreview();
    _phoneGpsFallbackService?.start();
    _usbService.start();
  }

  void _handleStateChanged() {
    final sessionState = _state.sessionState;
    if (_lastObservedSessionState == sessionState) {
      return;
    }
    _lastObservedSessionState = sessionState;

    final shouldRunForegroundService =
        sessionState == SessionState.armed ||
        sessionState == SessionState.logging;

    if (shouldRunForegroundService == _foregroundServiceRunning) {
      return;
    }

    _foregroundServiceRunning = shouldRunForegroundService;
    if (shouldRunForegroundService) {
      unawaited(
        _foregroundTelemetryService.start(
          title: 'ECT Telemetry Active',
          text: _state.sessionName.isEmpty
              ? 'Session is active.'
              : 'Session: ${_state.sessionName}',
        ),
      );
      return;
    }

    unawaited(_foregroundTelemetryService.stop());
  }

  @override
  void dispose() {
    _state.removeListener(_handleStateChanged);
    _state.onRequestReadableCopyPreview = null;
    _state.onRequestReadableCopyExport = null;
    _state.onReadableCopyRetentionDaysChanged = null;
    _state.onReadableCopyMaxFileBytesChanged = null;
    _state.onSimulationToggleChanged = null;
    _driverAlertService?.stop();
    if (_foregroundServiceRunning) {
      unawaited(_foregroundTelemetryService.stop());
      _foregroundServiceRunning = false;
    }
    _phoneGpsFallbackService?.stop();
    _sessionCheckpointService?.stop();
    _canTxService.dispose();
    _usbService.stop();
    _mqttService.stop();
    unawaited(_localSpoolService.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DashboardState>();

    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF121212),
      primaryColor: Colors.blueAccent,
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 72,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        titleLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Colors.white70,
        ),
        bodyMedium: TextStyle(fontSize: 18, color: Colors.white54),
      ),
    );

    final lightTheme = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      primaryColor: Colors.blueAccent,
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 72,
          fontWeight: FontWeight.bold,
          color: Colors.black,
        ),
        titleLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        bodyMedium: TextStyle(fontSize: 18, color: Colors.black54),
      ),
    );

    return MaterialApp(
      title: 'Telemetry Dashboard',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child!,
        );
      },
      theme: state.useLightTheme ? lightTheme : darkTheme,
      home: const DashboardScreen(),
    );
  }
}
