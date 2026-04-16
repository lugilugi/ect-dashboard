import 'package:flutter/material.dart';
import 'dart:collection';
import 'dart:async';
import 'dart:math';
import '../models/can_messages.dart';
import '../models/session_models.dart';
import '../models/driver_alert_models.dart';
import '../models/tx_can_command.dart';
import '../services/lap_boundary_service.dart';
import '../services/can_tx_service.dart';
import '../services/session_orchestrator.dart';
import '../services/readable_local_copy_writer.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';

enum MqttStatus { disconnected, connecting, connected }

class DashboardState extends ChangeNotifier {
  MqttStatus _mqttStatus = MqttStatus.disconnected;
  MqttStatus get mqttStatus => _mqttStatus;

  String _sessionName = "";
  String _sessionId = "";
  bool _isLogging = false;
  UiMode _uiMode = UiMode.driver;
  SessionState _sessionState = SessionState.idle;
  LapPhase _lapPhase = LapPhase.prestartCheck;

  final SessionOrchestrator _sessionOrchestrator = SessionOrchestrator();
  final LapBoundaryService _lapBoundaryService =
      LapBoundaryService.defaultConfig();

  bool enforceLapCompletionGate = false;
  bool startGateReady = false;
  int startGateRemainingMs = 0;
  String? startBlockReason;
  String? endBlockReason;
  String? lastCrossingReason;
  double? lastCrossingConfidence;

  int lapsPlanned = 1;
  int lapsCompleted = 0;
  int crossingDeadzoneMs = 3000;
  int crossingDeadzoneRemainingMs = 0;
  bool crossingValid = false;

  bool get isLogging => _isLogging;
  String get sessionName => _sessionName;
  String get sessionId => _sessionId;
  UiMode get uiMode => _uiMode;
  SessionState get sessionState => _sessionState;
  LapPhase get lapPhase => _lapPhase;

  String get uiModeWire => _uiMode.wireValue;
  String get sessionStateWire => _sessionState.wireValue;
  String get lapPhaseWire => _lapPhase.wireValue;
  String get lapProgressText => '$lapsCompleted/$lapsPlanned';

  bool get deadzoneActive => crossingDeadzoneRemainingMs > 0;

  String get deadzoneText {
    final seconds = crossingDeadzoneRemainingMs / 1000.0;
    return '${seconds.toStringAsFixed(1)}s';
  }

  String get crossingStatusText {
    switch (_lapPhase) {
      case LapPhase.prestartCheck:
        return 'PRESTART';
      case LapPhase.running:
        return 'RUN';
      case LapPhase.crossingCandidate:
        return 'CROSS?';
      case LapPhase.crossingDeadzone:
        return 'DEADZONE';
      case LapPhase.restartAllowed:
        return 'READY';
      case LapPhase.lapComplete:
        return 'LAP OK';
      case LapPhase.sessionComplete:
        return 'SESSION OK';
    }
  }

  String get gpsSourceText {
    if (usingPhoneGpsFallback) {
      return 'PHONE';
    }
    if (!gpsLocked) {
      return 'NONE';
    }
    return 'EXT';
  }

  String get oldestUnsentAgeText {
    if (unsentBatchCount <= 0) {
      return '0.0s';
    }

    final seconds = oldestUnsentAgeMs / 1000.0;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(1)}s';
    }

    final minutes = seconds ~/ 60;
    final remSeconds = seconds % 60;
    return '${minutes}m ${remSeconds.toStringAsFixed(0)}s';
  }

  String get spoolUsageText {
    if (spoolPendingBatchCapacity <= 0) {
      return '--';
    }
    return '$spoolPendingBatchCount/$spoolPendingBatchCapacity';
  }

  bool get gpsPermissionsHealthy =>
      notificationPermissionGranted && backgroundLocationPermissionGranted;

  String get gpsPermissionStatusText {
    if (gpsPermissionsHealthy) {
      return 'PERM OK';
    }

    final missing = <String>[];
    if (!notificationPermissionGranted) {
      missing.add('NOTIF');
    }
    if (!backgroundLocationPermissionGranted) {
      missing.add('BG');
    }
    return 'PERM ${missing.join('+')}';
  }

  SessionControlState get sessionControlState => SessionControlState(
    sessionState: _sessionState,
    uiMode: _uiMode,
    lapsPlanned: lapsPlanned,
    lapsCompleted: lapsCompleted,
    lapPhase: _lapPhase,
    crossingDeadzoneMs: crossingDeadzoneMs,
    crossingDeadzoneRemainingMs: crossingDeadzoneRemainingMs,
    crossingValid: crossingValid,
  );

  SessionCheckpointSnapshot buildSessionCheckpointSnapshot({
    required int lastSeqInSession,
    DateTime? nowUtc,
  }) {
    final updatedAt = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    return SessionCheckpointSnapshot(
      sessionId: _sessionId,
      sessionName: _sessionName,
      sessionState: _sessionState,
      uiMode: _uiMode,
      lapsPlanned: lapsPlanned,
      lapsCompleted: lapsCompleted,
      lapPhase: _lapPhase,
      crossingDeadzoneMs: crossingDeadzoneMs,
      crossingDeadzoneRemainingMs: crossingDeadzoneRemainingMs,
      crossingValid: crossingValid,
      lapNumber: lapNumber,
      sessionTimeSeconds: sessionTimeSeconds,
      lastSeqInSession: max(0, lastSeqInSession),
      gpsLocked: gpsLocked,
      usingPhoneGpsFallback: usingPhoneGpsFallback,
      updatedAtUtc: updatedAt,
    );
  }

  void restoreFromCheckpoint(SessionCheckpointSnapshot snapshot) {
    _sessionId = snapshot.sessionId;
    _sessionName = snapshot.sessionName;
    lapNumber = max(1, snapshot.lapNumber);
    sessionTimeSeconds = max(0, snapshot.sessionTimeSeconds);
    gpsLocked = snapshot.gpsLocked;
    usingPhoneGpsFallback = snapshot.usingPhoneGpsFallback;
    if (!usingPhoneGpsFallback) {
      phoneGpsAccuracyM = null;
    }

    startBlockReason = null;
    endBlockReason = null;
    _applySessionControlState(snapshot.controlState);

    final gateStatus = _sessionOrchestrator.evaluateStartGate(
      speedKmh: speedKmh,
      nowUtc: DateTime.now().toUtc(),
    );
    _updateStartGateFromDecision(gateStatus);
    notifyListeners();
  }

  double get commandAckRate {
    if (commandCompletionCount == 0) {
      return 0;
    }
    return commandAckCount / commandCompletionCount;
  }

  String get lastAlertSeverityText {
    return lastAlertSeverity?.wireValue ?? 'NONE';
  }

  String get alertVolumePercentText {
    return '${(alertVolume * 100).round()}%';
  }

  String get readableCopyRetentionDaysText {
    return '$readableCopyRetentionDays d';
  }

  String get readableCopyMaxFileSizeText {
    final mb = readableCopyMaxFileBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  String get readableCopyPreviewStatusText {
    if (readableCopyPreviewLoading) {
      return 'LOADING';
    }
    if (readableCopyPreviewError != null &&
        readableCopyPreviewError!.isNotEmpty) {
      return 'ERROR';
    }
    return 'READY';
  }

  int get commandTerminalCount {
    return commandCompletionCount + commandRejectedCount;
  }

  int get pendingTxCommandCount {
    return max(0, commandSentCount - commandTerminalCount);
  }

  String _mqttHost = "pitwall-laptop"; // Default value
  String get mqttHost => _mqttHost;

  void updateMqttHost(String newHost) {
    if (_mqttHost == newHost) return;
    _mqttHost = newHost;
    notifyListeners();
  }

  void setMqttStatus(MqttStatus status) {
    _mqttStatus = status;
    notifyListeners();
  }

  // GENERATE NAME (e.g., RUN_20260327_1430)
  String generateDefaultName() {
    final now = DateTime.now();
    return "RUN_${DateFormat('yyyyMMdd_HHmm').format(now)}";
  }

  // START SESSION
  bool startSession(String name, {int? plannedLaps}) {
    final resolvedName = name.isEmpty ? generateDefaultName() : name;
    if (_sessionId.isEmpty) {
      _sessionId = const Uuid().v4();
    }
    _sessionName = resolvedName;

    final armedControl = _sessionOrchestrator.arm(
      control: sessionControlState,
      plannedLaps: plannedLaps,
    );
    _applySessionControlState(armedControl);

    final decision = _sessionOrchestrator.requestStart(
      control: sessionControlState,
      speedKmh: speedKmh,
      nowUtc: DateTime.now().toUtc(),
    );
    _updateStartGateFromDecision(decision.startGateStatus);

    if (!decision.accepted) {
      startBlockReason = decision.reason;
      notifyListeners();
      return false;
    }

    sessionTimeSeconds = 0;
    lapNumber = 1;
    startBlockReason = null;
    endBlockReason = null;
    _applySessionControlState(decision.nextControl);
    notifyListeners();
    return true;
  }

  // STOP SESSION
  bool stopSession({bool abort = false}) {
    if (!abort && _requiresReplayDrainBeforeStop && unsentBatchCount > 0) {
      endBlockReason =
          'Stop blocked until recovered-session replay backlog is drained.';
      notifyListeners();
      return false;
    }

    final decision = _sessionOrchestrator.requestStop(
      control: sessionControlState,
      nowUtc: DateTime.now().toUtc(),
      abort: abort,
      enforceLapTarget: enforceLapCompletionGate,
    );

    if (!decision.accepted) {
      endBlockReason = decision.reason;
      notifyListeners();
      return false;
    }

    _applySessionControlState(decision.nextControl);
    endBlockReason = null;
    notifyListeners();
    return true;
  }

  void armSession({int? plannedLaps}) {
    final armedControl = _sessionOrchestrator.arm(
      control: sessionControlState,
      plannedLaps: plannedLaps,
    );
    _applySessionControlState(armedControl);
    notifyListeners();
  }

  void setUiMode(UiMode mode) {
    if (_uiMode == mode) {
      return;
    }
    _uiMode = mode;
    notifyListeners();
  }

  void setLapPhase(LapPhase phase) {
    if (_lapPhase == phase) {
      return;
    }
    _lapPhase = phase;
    notifyListeners();
  }

  void setLapsCompleted(int value) {
    final bounded = value.clamp(0, lapsPlanned);
    if (lapsCompleted == bounded) {
      return;
    }
    lapsCompleted = bounded;
    notifyListeners();
  }

  void setLapsPlanned(int value) {
    final bounded = value.clamp(1, 30);
    if (lapsPlanned == bounded) {
      return;
    }
    lapsPlanned = bounded;
    if (lapsCompleted > lapsPlanned) {
      lapsCompleted = lapsPlanned;
    }
    notifyListeners();
  }

  void setCrossingDeadzoneMs(int value) {
    final bounded = value.clamp(1000, 10000);
    if (crossingDeadzoneMs == bounded) {
      return;
    }
    crossingDeadzoneMs = bounded;
    if (crossingDeadzoneRemainingMs > crossingDeadzoneMs) {
      crossingDeadzoneRemainingMs = crossingDeadzoneMs;
    }
    notifyListeners();
  }

  void _setSessionState(SessionState next, {bool shouldNotify = true}) {
    if (_sessionState == next) {
      return;
    }
    _sessionState = next;
    _isLogging = _sessionState == SessionState.logging;
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void _applySessionControlState(SessionControlState control) {
    lapsPlanned = control.lapsPlanned;
    lapsCompleted = control.lapsCompleted;
    crossingDeadzoneMs = control.crossingDeadzoneMs;
    crossingDeadzoneRemainingMs = control.crossingDeadzoneRemainingMs;
    crossingValid = control.crossingValid;
    _uiMode = control.uiMode;
    _lapPhase = control.lapPhase;
    _setSessionState(control.sessionState, shouldNotify: false);
  }

  void _updateStartGateFromDecision(StartGateStatus status) {
    startGateReady = status.ready;
    startGateRemainingMs = status.holdRemainingMs;
  }

  void resetSessionState() {
    _sessionName = '';
    _sessionId = '';
    _lapPhase = LapPhase.prestartCheck;
    _requiresReplayDrainBeforeStop = false;
    lapsCompleted = 0;
    crossingValid = false;
    crossingDeadzoneRemainingMs = 0;
    startBlockReason = null;
    endBlockReason = null;
    lastCrossingReason = null;
    lastCrossingConfidence = null;
    _setSessionState(SessionState.idle, shouldNotify: false);
    _lapBoundaryService.resetTracking();
    notifyListeners();
  }

  void configureLapBoundary({required GeoPoint start, required GeoPoint end}) {
    _lapBoundaryService.setFinishLine(start: start, end: end);
    notifyListeners();
  }

  GeoPoint get lapBoundaryStart => _lapBoundaryService.config.finishLineStart;
  GeoPoint get lapBoundaryEnd => _lapBoundaryService.config.finishLineEnd;

  void processGpsSample({
    required double lat,
    required double lon,
    required double headingDeg,
    required double speedKmh,
    required DateTime timestampUtc,
    required String source,
  }) {
    final sampleTimestampUtc = timestampUtc.toUtc();
    currentGpsLat = lat;
    currentGpsLon = lon;
    currentGpsHeadingDeg = headingDeg;
    currentGpsSpeedKmh = speedKmh;
    currentGpsSampleAtUtc = sampleTimestampUtc;
    currentGpsSource = source;

    final session = sessionControlState;
    final eventSessionId = _sessionId.isEmpty ? 'pending-session' : _sessionId;
    final lapBoundaryResult = _lapBoundaryService.processSample(
      sample: GpsSample(
        point: GeoPoint(lat: lat, lon: lon),
        headingDeg: headingDeg,
        speedKmh: speedKmh,
        tsUtc: sampleTimestampUtc,
        source: source,
      ),
      control: session,
      sessionId: eventSessionId,
      lapNumber: max(1, lapsCompleted + 1),
    );

    switch (lapBoundaryResult.decision) {
      case LapCrossingDecision.none:
        return;
      case LapCrossingDecision.deadzone:
        _lapPhase = LapPhase.crossingDeadzone;
        crossingDeadzoneRemainingMs = lapBoundaryResult.deadzoneRemainingMs;
        notifyListeners();
        return;
      case LapCrossingDecision.rejected:
        final crossingEvent = lapBoundaryResult.crossingEvent;
        _lapPhase = LapPhase.crossingCandidate;
        crossingValid = false;
        lastCrossingReason = crossingEvent?.reason;
        lastCrossingConfidence = crossingEvent?.confidence;
        notifyListeners();
        return;
      case LapCrossingDecision.accepted:
        final crossingEvent = lapBoundaryResult.crossingEvent;
        if (crossingEvent == null) {
          return;
        }
        final nextControl = _sessionOrchestrator.applyLapAccepted(
          control: sessionControlState,
          deadzoneMs: crossingDeadzoneMs,
        );
        _applySessionControlState(nextControl);
        lastCrossingReason = null;
        lastCrossingConfidence = crossingEvent.confidence;
        lapNumber = max(1, lapsCompleted + 1);
        notifyListeners();
        return;
    }
  }

  // Pedal states
  double throttlePercent = 0.0;
  bool isBrakePressed = false;

  // Aux states
  bool leftTurn = false;
  bool rightTurn = false;
  bool brakeLight = false;
  bool headlights = false;
  bool hazards = false;
  bool horn = false;
  bool wipers = false;

  // Power & Environment
  double mainVoltage = 0.0;
  double current780 = 0.0;
  double current740 = 0.0;
  double mcTempC = 45.0;
  double battTempC = 35.0;

  // Energy
  double energyJ780 = 0.0;
  double energyJ740 = 0.0;

  // Connections
  bool isConnected = false;
  bool isServerConnected = false;
  int unsentBatchCount = 0;
  int oldestUnsentAgeMs = 0;
  int spoolPendingBatchCount = 0;
  int spoolPendingBatchCapacity = 0;
  bool spoolCapacityWarning = false;
  int recoveryResumeCount = 0;
  DateTime? lastRecoveryAtUtc;
  bool _requiresReplayDrainBeforeStop = false;
  DateTime? _oldestUnsentEnqueuedAtUtc;
  bool enableSimulation = false;
  bool isSimulated = false;

  // EV Metrics
  double speedKmh = 0.0;
  double distanceKm = 0.0;
  int lapNumber = 1;

  final Queue<double> _speedHistory = Queue<double>();
  final Queue<double> _powerKwHistory = Queue<double>();

  double instKmPerKwh = 0.0;
  double avgKmPerKwh = 0.0;

  int errorCount = 0;
  String lastErrorCode = "OK";
  String strategy = "PACE";

  int commandSentCount = 0;
  int commandCompletionCount = 0;
  int commandAckCount = 0;
  int commandNackCount = 0;
  int commandTimeoutCount = 0;
  int commandRejectedCount = 0;
  final Queue<String> recentCommandEvents = Queue<String>();

  bool alertAudioEnabled = true;
  bool alertHapticsEnabled = true;
  bool alertAdvisoryEnabled = true;
  double alertVolume = 0.75;
  int alertCooldownMs = 1500;
  int alertCriticalRepeatCount = 2;
  int alertCriticalRepeatIntervalMs = 550;
  int alertEmitCount = 0;
  String lastAlertCode = 'NONE';
  String lastAlertReasonClass = 'NONE';
  DriverAlertSeverity? lastAlertSeverity;
  DateTime? lastAlertAtUtc;
  final Queue<String> recentAlertEvents = Queue<String>();

  int readableCopyRetentionDays = 7;
  int readableCopyMaxFileBytes = 4 * 1024 * 1024;
  bool readableCopyPreviewLoading = false;
  int readableCopyFileCount = 0;
  String? readableCopyDirectoryPath;
  String? readableCopyPreviewError;
  String? readableCopyLastExportPath;
  DateTime? readableCopyLastUpdatedAtUtc;
  final Queue<String> readableCopyRecentLines = Queue<String>();

  Future<void> Function()? onRequestAlertTestTone;
  Future<ReadableLocalCopyPreview> Function()? onRequestReadableCopyPreview;
  Future<String?> Function()? onRequestReadableCopyExport;
  Future<void> Function(int retentionDays)? onReadableCopyRetentionDaysChanged;
  Future<void> Function(int maxFileBytes)? onReadableCopyMaxFileBytesChanged;
  void Function(bool enabled)? onSimulationToggleChanged;

  Future<TxCommandResult> Function(TxCanCommand command)? onTxCommand;

  // Debug & Engineer screen
  Map<int, String> lastCanPayloads = {};
  List<double> bmsCells = List.filled(24, 3.80);
  double bus12V = 12.4;
  List<String> mcFaults = ["NONE"];

  // GPS
  int gpsSatellites = 0;
  bool gpsLocked = false;
  bool usingPhoneGpsFallback = false;
  double? currentGpsLat;
  double? currentGpsLon;
  double? currentGpsHeadingDeg;
  double? currentGpsSpeedKmh;
  DateTime? currentGpsSampleAtUtc;
  String? currentGpsSource;
  bool notificationPermissionGranted = true;
  bool backgroundLocationPermissionGranted = true;
  int gpsSourceTransitions = 0;
  DateTime? lastGpsSourceChangedAtUtc;
  double? phoneGpsAccuracyM;
  final Duration externalGpsTimeout;
  DateTime _lastExternalGpsMessageAt = DateTime.now();

  bool get isExternalGpsStale {
    return DateTime.now().difference(_lastExternalGpsMessageAt) >
        externalGpsTimeout;
  }

  String get gpsStatusText {
    if (!gpsLocked) {
      return "NO FIX";
    }
    if (usingPhoneGpsFallback) {
      if (phoneGpsAccuracyM != null) {
        return "PHONE FIX (${phoneGpsAccuracyM!.toStringAsFixed(0)}m)";
      }
      return "PHONE FIX";
    }
    final satCount = gpsSatellites < 0 ? 0 : gpsSatellites;
    return "3D FIX ($satCount)";
  }

  bool get hasCurrentGpsSample =>
      currentGpsLat != null && currentGpsLon != null;

  GeoPoint? get currentGpsPoint {
    final lat = currentGpsLat;
    final lon = currentGpsLon;
    if (lat == null || lon == null) {
      return null;
    }
    return GeoPoint(lat: lat, lon: lon);
  }

  // Configuration
  String apiUrl = "https://your-backend-api.local/api/telemetry";
  List<double> throttleMap = [0.0, 25.0, 50.0, 75.0, 100.0];
  List<double> throttleMapDraft = [0.0, 25.0, 50.0, 75.0, 100.0];
  String selectedThrottleMapProfile = 'Default';

  final Map<String, List<double>> _throttleMapPresets = {
    'Default': [0.0, 25.0, 50.0, 75.0, 100.0],
  };

  List<String> get throttleMapPresetNames {
    return _throttleMapPresets.keys.toList(growable: false);
  }

  List<String> get customThrottleMapPresetNames {
    return _throttleMapPresets.keys
        .where((name) => name != 'Default')
        .toList(growable: false);
  }

  bool get throttleMapDirty {
    return !_throttleMapEquals(throttleMap, throttleMapDraft);
  }

  String get crossingDeadzoneConfigText {
    final seconds = crossingDeadzoneMs / 1000.0;
    return '${seconds.toStringAsFixed(1)} s';
  }

  // Theme
  bool useLightTheme = false;
  bool useDictionaryAuxDispatch = true;

  // Speed bar thresholds
  double speedUpperThreshold = 40.0;
  double speedLowerThreshold = 25.0;

  // Configurable graph
  String graphMetric = "speed"; // "speed", "power", "efficiency"
  final Queue<double> graphHistory = Queue<double>();
  static const int maxGraphPoints = 100;

  void Function(String)? onUsbTx;

  void sendUsbCommand(String cmd) {
    onUsbTx?.call(cmd);
  }

  Future<TxCommandResult> sendDictionaryCommand(TxCanCommand command) async {
    final handler = onTxCommand;
    if (handler == null) {
      final rejected = TxCommandResult(
        status: TxCommandStatus.rejected,
        sequence: null,
        retries: 0,
        reason: 'tx_service_unavailable',
        command: command,
      );
      recordCanTxResult(rejected);
      return rejected;
    }

    commandSentCount += 1;
    notifyListeners();
    final result = await handler(command);
    return result;
  }

  void recordCanTxResult(TxCommandResult result) {
    switch (result.status) {
      case TxCommandStatus.acked:
        commandCompletionCount += 1;
        commandAckCount += 1;
        break;
      case TxCommandStatus.nacked:
        commandCompletionCount += 1;
        commandNackCount += 1;
        break;
      case TxCommandStatus.timeout:
        commandCompletionCount += 1;
        commandTimeoutCount += 1;
        break;
      case TxCommandStatus.rejected:
        commandRejectedCount += 1;
        break;
    }

    final seqText = result.sequence?.toString() ?? '-';
    final reason = result.reason == null ? '' : ' (${result.reason})';
    final line =
        '${DateTime.now().toIso8601String()} ${result.command.commandKey} ${result.status.name.toUpperCase()} seq=$seqText retry=${result.retries}$reason';
    recentCommandEvents.addLast(line);
    while (recentCommandEvents.length > 25) {
      recentCommandEvents.removeFirst();
    }

    notifyListeners();
  }

  // Session timer
  int sessionTimeSeconds = 0;
  Timer? _sessionTimer;

  DashboardState({this.externalGpsTimeout = const Duration(seconds: 5)}) {
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      sessionTimeSeconds++;

      if (_oldestUnsentEnqueuedAtUtc != null && unsentBatchCount > 0) {
        oldestUnsentAgeMs = DateTime.now()
            .toUtc()
            .difference(_oldestUnsentEnqueuedAtUtc!)
            .inMilliseconds;
      } else if (oldestUnsentAgeMs != 0) {
        oldestUnsentAgeMs = 0;
      }

      if (crossingDeadzoneRemainingMs > 0) {
        crossingDeadzoneRemainingMs = max(
          0,
          crossingDeadzoneRemainingMs - 1000,
        );
        if (crossingDeadzoneRemainingMs == 0 &&
            _lapPhase == LapPhase.crossingDeadzone) {
          _lapPhase = LapPhase.running;
        }
      }

      notifyListeners();
    });

    final gateStatus = _sessionOrchestrator.evaluateStartGate(
      speedKmh: speedKmh,
      nowUtc: DateTime.now().toUtc(),
    );
    _updateStartGateFromDecision(gateStatus);
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    super.dispose();
  }

  String get sessionTimeString {
    int h = sessionTimeSeconds ~/ 3600;
    int m = (sessionTimeSeconds % 3600) ~/ 60;
    int s = sessionTimeSeconds % 60;
    if (h > 0) {
      return '${h.toString()}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get systemTimeString {
    DateTime now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
  }

  void setConnectionState(bool state) {
    if (isConnected != state) {
      isConnected = state;
      notifyListeners();
    }
  }

  void setSimulatedState(bool state) {
    if (isSimulated != state) {
      isSimulated = state;
      notifyListeners();
    }
  }

  void toggleSimulation(bool val) {
    enableSimulation = val;
    if (!val) {
      isSimulated = false;
    }
    notifyListeners();
    onSimulationToggleChanged?.call(val);
  }

  void toggleTheme(bool val) {
    useLightTheme = val;
    notifyListeners();
  }

  void toggleDictionaryAuxDispatch(bool enabled) {
    if (useDictionaryAuxDispatch == enabled) {
      return;
    }
    useDictionaryAuxDispatch = enabled;
    notifyListeners();
  }

  void setAlertAudioEnabled(bool enabled) {
    if (alertAudioEnabled == enabled) {
      return;
    }
    alertAudioEnabled = enabled;
    notifyListeners();
  }

  void setAlertHapticsEnabled(bool enabled) {
    if (alertHapticsEnabled == enabled) {
      return;
    }
    alertHapticsEnabled = enabled;
    notifyListeners();
  }

  void setAlertAdvisoryEnabled(bool enabled) {
    if (alertAdvisoryEnabled == enabled) {
      return;
    }
    alertAdvisoryEnabled = enabled;
    notifyListeners();
  }

  void setAlertVolume(double value) {
    final bounded = value.clamp(0.0, 1.0);
    if ((alertVolume - bounded).abs() < 0.001) {
      return;
    }
    alertVolume = bounded;
    notifyListeners();
  }

  void setAlertCooldownMs(int value) {
    final bounded = value.clamp(0, 10000);
    if (alertCooldownMs == bounded) {
      return;
    }
    alertCooldownMs = bounded;
    notifyListeners();
  }

  void setAlertCriticalRepeatCount(int value) {
    final bounded = value.clamp(0, 6);
    if (alertCriticalRepeatCount == bounded) {
      return;
    }
    alertCriticalRepeatCount = bounded;
    notifyListeners();
  }

  void setAlertCriticalRepeatIntervalMs(int value) {
    final bounded = value.clamp(150, 5000);
    if (alertCriticalRepeatIntervalMs == bounded) {
      return;
    }
    alertCriticalRepeatIntervalMs = bounded;
    notifyListeners();
  }

  void requestAlertTestTone() {
    final callback = onRequestAlertTestTone;
    if (callback == null) {
      return;
    }
    unawaited(callback());
  }

  Future<void> refreshReadableCopyPreview() async {
    final callback = onRequestReadableCopyPreview;
    if (callback == null) {
      readableCopyPreviewError = 'Readable local mirror service unavailable.';
      notifyListeners();
      return;
    }

    readableCopyPreviewLoading = true;
    readableCopyPreviewError = null;
    notifyListeners();

    try {
      final preview = await callback();
      readableCopyDirectoryPath = preview.directoryPath;
      readableCopyFileCount = preview.fileCount;
      readableCopyRecentLines
        ..clear()
        ..addAll(preview.recentLines);
      while (readableCopyRecentLines.length > 64) {
        readableCopyRecentLines.removeFirst();
      }
      readableCopyLastUpdatedAtUtc = DateTime.now().toUtc();
    } catch (e) {
      readableCopyPreviewError = 'Preview refresh failed: $e';
    } finally {
      readableCopyPreviewLoading = false;
      notifyListeners();
    }
  }

  Future<void> exportReadableCopySnapshot() async {
    final callback = onRequestReadableCopyExport;
    if (callback == null) {
      readableCopyPreviewError = 'Readable local mirror export unavailable.';
      notifyListeners();
      return;
    }

    readableCopyPreviewError = null;
    notifyListeners();
    try {
      final exportPath = await callback();
      if (exportPath == null || exportPath.isEmpty) {
        readableCopyPreviewError =
            'No readable local mirror files are available to export.';
      } else {
        readableCopyLastExportPath = exportPath;
      }
    } catch (e) {
      readableCopyPreviewError = 'Export failed: $e';
    }
    notifyListeners();
  }

  void setReadableCopyRetentionDays(int value) {
    final bounded = value.clamp(1, 30);
    if (readableCopyRetentionDays == bounded) {
      return;
    }
    readableCopyRetentionDays = bounded;
    final callback = onReadableCopyRetentionDaysChanged;
    if (callback != null) {
      unawaited(callback(readableCopyRetentionDays));
    }
    notifyListeners();
  }

  void setReadableCopyMaxFileBytes(int value) {
    final bounded = value.clamp(128 * 1024, 64 * 1024 * 1024);
    if (readableCopyMaxFileBytes == bounded) {
      return;
    }
    readableCopyMaxFileBytes = bounded;
    final callback = onReadableCopyMaxFileBytesChanged;
    if (callback != null) {
      unawaited(callback(readableCopyMaxFileBytes));
    }
    notifyListeners();
  }

  void setReadableCopyDirectoryPath(String? value) {
    if (readableCopyDirectoryPath == value) {
      return;
    }
    readableCopyDirectoryPath = value;
    notifyListeners();
  }

  void recordAlertEmission({
    required String alertCode,
    required DriverAlertSeverity severity,
    String? reasonClass,
    DateTime? atUtc,
  }) {
    alertEmitCount += 1;
    lastAlertCode = alertCode;
    lastAlertSeverity = severity;
    lastAlertReasonClass = reasonClass ?? 'NONE';
    lastAlertAtUtc = (atUtc ?? DateTime.now().toUtc()).toUtc();

    final reasonText = lastAlertReasonClass == 'NONE'
        ? ''
        : ' [$lastAlertReasonClass]';
    final line =
        '${lastAlertAtUtc!.toIso8601String()} ${severity.wireValue} $alertCode$reasonText';
    recentAlertEvents.addLast(line);
    while (recentAlertEvents.length > 25) {
      recentAlertEvents.removeFirst();
    }

    notifyListeners();
  }

  void updateSpeedThresholds(double lower, double upper) {
    speedLowerThreshold = lower;
    speedUpperThreshold = upper;
    notifyListeners();
  }

  void updateGraphMetric(String metric) {
    graphMetric = metric;
    graphHistory.clear();
    notifyListeners();
  }

  void setServerConnectionState(bool state) {
    if (isServerConnected != state) {
      isServerConnected = state;
      notifyListeners();
    }
  }

  void updateMqttBacklog({
    required int count,
    required DateTime? oldestEnqueuedAtUtc,
  }) {
    final sanitizedCount = max(0, count);
    final nextOldest = sanitizedCount > 0 ? oldestEnqueuedAtUtc : null;
    final nextAgeMs = nextOldest == null
        ? 0
        : DateTime.now().toUtc().difference(nextOldest).inMilliseconds;

    final changed =
        unsentBatchCount != sanitizedCount ||
        _oldestUnsentEnqueuedAtUtc != nextOldest ||
        oldestUnsentAgeMs != nextAgeMs;

    unsentBatchCount = sanitizedCount;
    _oldestUnsentEnqueuedAtUtc = nextOldest;
    oldestUnsentAgeMs = nextAgeMs;

    if (_requiresReplayDrainBeforeStop && sanitizedCount == 0) {
      _requiresReplayDrainBeforeStop = false;
    }

    if (changed) {
      notifyListeners();
    }
  }

  void updateSpoolHealth({
    required int pendingBatchCount,
    required int pendingBatchCapacity,
  }) {
    final sanitizedPending = max(0, pendingBatchCount);
    final sanitizedCapacity = max(0, pendingBatchCapacity);
    final warningThreshold = sanitizedCapacity <= 0
        ? 0
        : ((sanitizedCapacity * 0.8).ceil());
    final warning =
        sanitizedCapacity > 0 && sanitizedPending >= warningThreshold;

    final changed =
        spoolPendingBatchCount != sanitizedPending ||
        spoolPendingBatchCapacity != sanitizedCapacity ||
        spoolCapacityWarning != warning;

    spoolPendingBatchCount = sanitizedPending;
    spoolPendingBatchCapacity = sanitizedCapacity;
    spoolCapacityWarning = warning;

    if (changed) {
      notifyListeners();
    }
  }

  void recordRecoveryResume({DateTime? atUtc}) {
    recoveryResumeCount += 1;
    _requiresReplayDrainBeforeStop = true;
    lastRecoveryAtUtc = (atUtc ?? DateTime.now().toUtc()).toUtc();
    notifyListeners();
  }

  void updateApiUrl(String url) {
    apiUrl = url;
    notifyListeners();
  }

  void updateThrottleMap(int index, double value) {
    final bounded = value.clamp(0.0, 100.0);
    throttleMapDraft[index] = bounded;
    _refreshThrottleMapProfileSelection();
    notifyListeners();
  }

  void loadThrottleMapPreset(String profileName) {
    final preset = _throttleMapPresets[profileName];
    if (preset == null) {
      return;
    }

    throttleMapDraft = List<double>.from(preset);
    selectedThrottleMapProfile = profileName;
    notifyListeners();
  }

  bool addThrottleMapPreset(String profileName) {
    final normalized = profileName.trim();
    if (normalized.isEmpty) {
      return false;
    }

    if (normalized.toLowerCase() == 'default') {
      return false;
    }

    final duplicate = _throttleMapPresets.keys.any(
      (existing) => existing.toLowerCase() == normalized.toLowerCase(),
    );
    if (duplicate) {
      return false;
    }

    _throttleMapPresets[normalized] = List<double>.from(throttleMapDraft);
    selectedThrottleMapProfile = normalized;
    notifyListeners();
    return true;
  }

  void resetThrottleMapDraftToApplied() {
    throttleMapDraft = List<double>.from(throttleMap);
    _refreshThrottleMapProfileSelection();
    notifyListeners();
  }

  void applyThrottleMapDraft() {
    throttleMap = List<double>.from(throttleMapDraft);
    _refreshThrottleMapProfileSelection();

    final mapPayload = throttleMap
        .map((value) => value.round().clamp(0, 100))
        .join(',');
    sendUsbCommand('CMD:THROTTLE_MAP:$mapPayload\n');

    notifyListeners();
  }

  void _refreshThrottleMapProfileSelection() {
    String? matched;
    for (final entry in _throttleMapPresets.entries) {
      if (_throttleMapEquals(entry.value, throttleMapDraft)) {
        matched = entry.key;
        break;
      }
    }

    selectedThrottleMapProfile = matched ?? '';
  }

  bool _throttleMapEquals(List<double> a, List<double> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.5) {
        return false;
      }
    }
    return true;
  }

  void updateThermals(double mc, double batt) {
    mcTempC = mc;
    battTempC = batt;
    notifyListeners();
  }

  void updateDashStatus(DashStatusPayload payload) {
    errorCount = payload.errorCount;
    lastErrorCode = payload.lastErrorCode;
    strategy = payload.strategy;
    mcTempC = payload.mcTempC;
    battTempC = payload.battTempC;
    notifyListeners();
  }

  void updateErrorCode(String code) {
    lastErrorCode = code;
    notifyListeners();
  }

  void updateRawCan(int id, String payloadHex) {
    lastCanPayloads[id] = payloadHex;
  }

  void updateExternalGpsStatus({
    required int satellites,
    required bool locked,
  }) {
    _lastExternalGpsMessageAt = DateTime.now();
    if (usingPhoneGpsFallback) {
      gpsSourceTransitions += 1;
      lastGpsSourceChangedAtUtc = DateTime.now().toUtc();
    }
    gpsSatellites = satellites;
    gpsLocked = locked;
    usingPhoneGpsFallback = false;
    phoneGpsAccuracyM = null;
    notifyListeners();
  }

  void updateGpsPermissionStatus({
    required bool notificationGranted,
    required bool backgroundLocationGranted,
  }) {
    final changed =
        notificationPermissionGranted != notificationGranted ||
        backgroundLocationPermissionGranted != backgroundLocationGranted;
    notificationPermissionGranted = notificationGranted;
    backgroundLocationPermissionGranted = backgroundLocationGranted;
    if (changed) {
      notifyListeners();
    }
  }

  void markExternalGpsHeartbeat() {
    _lastExternalGpsMessageAt = DateTime.now();
    if (usingPhoneGpsFallback) {
      usingPhoneGpsFallback = false;
      phoneGpsAccuracyM = null;
      notifyListeners();
    }
  }

  void updatePhoneGpsFallback({required bool locked, double? accuracyM}) {
    if (!isExternalGpsStale) {
      return;
    }

    final boundedAccuracy = accuracyM?.clamp(0.0, 9999.0).toDouble();
    final hasAccuracyChanged =
        (phoneGpsAccuracyM == null && boundedAccuracy != null) ||
        (phoneGpsAccuracyM != null && boundedAccuracy == null) ||
        (phoneGpsAccuracyM != null &&
            boundedAccuracy != null &&
            (phoneGpsAccuracyM! - boundedAccuracy).abs() >= 1.0);

    final changed =
        gpsLocked != locked || !usingPhoneGpsFallback || hasAccuracyChanged;

    if (!usingPhoneGpsFallback) {
      gpsSourceTransitions += 1;
      lastGpsSourceChangedAtUtc = DateTime.now().toUtc();
    }

    gpsLocked = locked;
    gpsSatellites = -1;
    usingPhoneGpsFallback = true;
    phoneGpsAccuracyM = boundedAccuracy;

    if (changed) {
      notifyListeners();
    }
  }

  void updateEngineerMock(List<double> cells, double bus, int sats, bool lock) {
    bmsCells = cells;
    bus12V = bus;
    _lastExternalGpsMessageAt = DateTime.now();
    gpsSatellites = sats;
    gpsLocked = lock;
    usingPhoneGpsFallback = false;
    phoneGpsAccuracyM = null;
    notifyListeners();
  }

  void updatePedal(PedalPayload payload) {
    throttlePercent = payload.throttlePercent;
    isBrakePressed = payload.isBrakePressed;
    notifyListeners();
  }

  void updateAux(AuxControlPayload payload) {
    leftTurn = payload.leftTurn;
    rightTurn = payload.rightTurn;
    brakeLight = payload.brakeLight;
    headlights = payload.headlights;
    hazards = payload.hazards;
    horn = payload.horn;
    wipers = payload.wipers;
    notifyListeners();
  }

  void updatePower(PowerPayload payload, int id) {
    mainVoltage = payload.voltage;
    if (id == CanMsgID.pwrMonitor780) {
      current780 = payload.current780;
    } else if (id == CanMsgID.pwrMonitor740) {
      current740 = payload.current740;
    }
    _updateEfficiency();
    notifyListeners();
  }

  void updateEnergy(EnergyPayload payload) {
    energyJ780 = payload.joules780;
    energyJ740 = payload.joules740;
    notifyListeners();
  }

  void updateErrorCount(int count) {
    errorCount = count;
    notifyListeners();
  }

  void updateStrategy(String str) {
    strategy = str;
    notifyListeners();
  }

  void updateMotion(double speed, double distance, int lap) {
    speedKmh = speed;
    distanceKm = distance;
    lapNumber = lap;
    final gateStatus = _sessionOrchestrator.evaluateStartGate(
      speedKmh: speed,
      nowUtc: DateTime.now().toUtc(),
    );
    _updateStartGateFromDecision(gateStatus);
    _updateEfficiency();
    notifyListeners();
  }

  void _updateEfficiency() {
    double powerKw = (mainVoltage * current780) / 1000.0;

    _speedHistory.addLast(speedKmh);
    _powerKwHistory.addLast(powerKw);
    if (_speedHistory.length > 10) {
      _speedHistory.removeFirst();
      _powerKwHistory.removeFirst();
    }

    double avgWindowSpeed =
        _speedHistory.reduce((a, b) => a + b) / _speedHistory.length;
    double avgWindowPower =
        _powerKwHistory.reduce((a, b) => a + b) / _powerKwHistory.length;

    if (avgWindowPower > 0.5 && avgWindowSpeed > 1.0) {
      instKmPerKwh = avgWindowSpeed / avgWindowPower;
    } else if (powerKw < 0.0 && avgWindowSpeed > 1) {
      instKmPerKwh = 99.9; // Regen max-out
    } else {
      instKmPerKwh = 0.0;
    }

    double totalEnergyKwh = energyJ780 / 3600000.0;
    if (totalEnergyKwh > 0.001 && distanceKm > 0.001) {
      avgKmPerKwh = distanceKm / totalEnergyKwh;
    }

    // Update rolling graph history
    double graphVal;
    switch (graphMetric) {
      case "power":
        graphVal = powerKw * 1000; // W
        break;
      case "efficiency":
        graphVal = instKmPerKwh;
        break;
      default:
        graphVal = speedKmh;
    }
    graphHistory.addLast(graphVal);
    while (graphHistory.length > maxGraphPoints) {
      graphHistory.removeFirst();
    }
  }
}
