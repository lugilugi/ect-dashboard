import 'package:flutter/material.dart';
import 'dart:collection';
import 'dart:async';
import 'dart:math';
import 'package:telemetry_dashboard/models/telemetry/can_messages.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/alerts/driver_alert_models.dart';
import 'package:telemetry_dashboard/models/telemetry/tx_can_command.dart';
import 'package:telemetry_dashboard/services/orchestration/lap_boundary_service.dart';
import 'package:telemetry_dashboard/services/ingest/can_tx_service.dart';
import 'package:telemetry_dashboard/services/orchestration/session_orchestrator.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/persistence/readable_local_copy_writer.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';

/// A single completed lap crossing (geofence mode), with the GPS position
/// where the finish line was crossed. Bounded history for map visuals.
class LapCrossingRecord {
  final int lapNumber;
  final double lat;
  final double lon;
  final DateTime tsWallUtc;

  const LapCrossingRecord({
    required this.lapNumber,
    required this.lat,
    required this.lon,
    required this.tsWallUtc,
  });
}

class _SessionTicker {  final SessionControlStore _sessionControl;
  final VoidCallback _onTick;

  Timer? _timer;

  _SessionTicker({
    required SessionControlStore sessionControl,
    required VoidCallback onTick,
  }) : _sessionControl = sessionControl,
       _onTick = onTick;

  void start() {
    if (_timer != null) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    _sessionControl.advanceOneSecond();

    _onTick();
  }
}

class AlertStateStore {
  bool alertAudioEnabled = true;
  bool alertHapticsEnabled = true;
  bool alertAdvisoryEnabled = true;
  double alertVolume = 0.75;
  int alertCooldownMs = 1500;
  int alertCriticalRepeatCount = 2;
  int alertCriticalRepeatIntervalMs = 550;
  String lastAlertCode = 'NONE';
  String lastAlertReasonClass = 'NONE';
  DriverAlertSeverity? lastAlertSeverity;
  DateTime? lastAlertAtUtc;
  Future<void> Function()? onRequestAlertTestTone;
  final Map<AlertVariableKey, AlertVariableSettings> alertVariables = {
    for (final spec in alertVariableSpecs)
      spec.key: AlertVariableSettings(
        enabled: spec.defaultEnabled,
        minThreshold: spec.defaultMin,
        maxThreshold: spec.defaultMax,
        cue: spec.defaultCue,
      ),
  };
}

class ReadableCopyStateStore {
  int retentionDays = 7;
  int maxFileBytes = 4 * 1024 * 1024;
  bool previewLoading = false;
  int fileCount = 0;
  String? directoryPath;
  String? previewError;
  String? lastExportPath;
  DateTime? lastUpdatedAtUtc;
  final Queue<String> recentLines = Queue<String>();
  Future<ReadableLocalCopyPreview> Function()? onRequestPreview;
  Future<String?> Function()? onRequestExport;
  Future<void> Function(int retentionDays)? onRetentionDaysChanged;
  Future<void> Function(int maxFileBytes)? onMaxFileBytesChanged;
}

class ConfigStateStore {
  List<double> throttleMap = [0.0, 25.0, 50.0, 75.0, 100.0];
  List<double> throttleMapDraft = [0.0, 25.0, 50.0, 75.0, 100.0];
  String selectedThrottleMapProfile = 'Default';
  final Map<String, List<double>> throttleMapPresets = {
    'Default': [0.0, 25.0, 50.0, 75.0, 100.0],
  };
  bool useLightTheme = false;
  bool useDictionaryAuxDispatch = true;
  double speedUpperThreshold = 40.0;
  double speedLowerThreshold = 25.0;
}

class TelemetryMetricsStore {
  // Pedal states
  double throttlePercent = 0.0;
  bool isBrakePressed = false;

  // Aux states
  bool leftTurn = false;
  bool rightTurn = false;
  bool headlights = false;
  bool hazards = false;
  bool horn = false;
  bool wipers = false;

  // Power & Environment
  double mainVoltage = 0.0;
  double current780 = 0.0;
  double mcTempC = 45.0;
  double battTempC = 35.0;

  // Energy
  double energyJ780 = 0.0;

  // EV Metrics
  double speedKmh = 0.0;
  double distanceKm = 0.0;
  int lapNumber = 1;

  final Queue<double> speedHistory = Queue<double>();
  final Queue<double> powerKwHistory = Queue<double>();

  double instKmPerKwh = 0.0;
  double avgKmPerKwh = 0.0;

  // Debug & Engineer screen
  Map<int, String> lastCanPayloads = {};
  List<double> bmsCells = List.filled(24, 3.80);
  double bus12V = 12.4;
  List<String> mcFaults = ["NONE"];

  int errorCount = 0;
  String lastErrorCode = "OK";
  String strategy = "PACE";
}

class GpsStateStore {
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
  double? phoneGpsAccuracyM;
  DateTime lastExternalGpsMessageAt = DateTime.now();
  double? lastKnownLat;
  double? lastKnownLon;
}

class DashboardState extends ChangeNotifier {
  String _sessionName = "";
  String _sessionId = "";
  final SessionControlStore _sessionControl = SessionControlStore();
  SpoolHealthStore _spoolHealth = SpoolHealthStore();
  bool _ownsSpoolHealth = true;
  final AlertStateStore _alerts = AlertStateStore();
  final ReadableCopyStateStore _readableCopy = ReadableCopyStateStore();
  final ConfigStateStore _config = ConfigStateStore();
  final TelemetryMetricsStore _metrics = TelemetryMetricsStore();
  final GpsStateStore _gps = GpsStateStore();

  SpoolHealthStore get spoolHealth => _spoolHealth;
  SessionControlStore get sessionControl => _sessionControl;
  AlertStateStore get alerts => _alerts;
  ReadableCopyStateStore get readableCopy => _readableCopy;
  ConfigStateStore get config => _config;
  TelemetryMetricsStore get metrics => _metrics;
  GpsStateStore get gps => _gps;

  void attachSpoolHealthStore(SpoolHealthStore store) {
    if (identical(_spoolHealth, store)) {
      return;
    }

    _spoolHealth.removeListener(_handleSpoolHealthChanged);
    if (_ownsSpoolHealth) {
      _spoolHealth.dispose();
    }

    _spoolHealth = store;
    _ownsSpoolHealth = false;
    _spoolHealth.addListener(_handleSpoolHealthChanged);
    notifyListeners();
  }

  UiMode get _uiMode => _sessionControl.uiMode;
  set _uiMode(UiMode value) => _sessionControl.uiMode = value;

  SessionState get _sessionState => _sessionControl.sessionState;

  LapPhase get _lapPhase => _sessionControl.lapPhase;
  set _lapPhase(LapPhase value) => _sessionControl.lapPhase = value;

  bool get _isLogging => _sessionControl.isLogging;

  int get lapsCompleted => _sessionControl.lapsCompleted;
  set lapsCompleted(int value) => _sessionControl.lapsCompleted = value;

  int get crossingDeadzoneMs => _sessionControl.crossingDeadzoneMs;
  set crossingDeadzoneMs(int value) =>
      _sessionControl.crossingDeadzoneMs = value;

  int get crossingDeadzoneRemainingMs =>
      _sessionControl.crossingDeadzoneRemainingMs;
  set crossingDeadzoneRemainingMs(int value) =>
      _sessionControl.crossingDeadzoneRemainingMs = value;

  bool get crossingValid => _sessionControl.crossingValid;
  set crossingValid(bool value) => _sessionControl.crossingValid = value;

  int get sessionTimeSeconds => _sessionControl.sessionTimeSeconds;
  set sessionTimeSeconds(int value) =>
      _sessionControl.sessionTimeSeconds = value;

  final SessionOrchestrator _sessionOrchestrator = SessionOrchestrator();
  final LapBoundaryService _lapBoundaryService =
      LapBoundaryService.defaultConfig();


  String? startBlockReason;
  String? endBlockReason;
  String? lastCrossingReason;

  LapDividerMode lapDividerMode = LapDividerMode.geofence;
  double distanceLapDividerKm = 0.25;
  int gpsFallbackPeriodMs = 5000;
  double? _nextDistanceDividerKm;
  bool _lapBoundaryConfigured = false;
  static const int maxLapCrossingRecords = 12;
  final List<LapCrossingRecord> _lapCrossings = <LapCrossingRecord>[];

  bool get lapBoundaryConfigured => _lapBoundaryConfigured;
  List<LapCrossingRecord> get lapCrossings =>
      List<LapCrossingRecord>.unmodifiable(_lapCrossings);

  void _recordLapCrossing({
    required int lapNumber,
    required double lat,
    required double lon,
    required DateTime tsWallUtc,
  }) {
    _lapCrossings.add(
      LapCrossingRecord(
        lapNumber: lapNumber,
        lat: lat,
        lon: lon,
        tsWallUtc: tsWallUtc.toUtc(),
      ),
    );
    if (_lapCrossings.length > maxLapCrossingRecords) {
      _lapCrossings.removeAt(0);
    }
  }

  bool get isLogging => _isLogging;
  String get sessionName => _sessionName;
  String get sessionId => _sessionId;
  UiMode get uiMode => _uiMode;
  SessionState get sessionState => _sessionState;
  LapPhase get lapPhase => _lapPhase;

  String get sessionStateWire => _sessionState.wireValue;

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
      case LapPhase.lapComplete:
        return 'LAP OK';
      case LapPhase.sessionComplete:
        return 'SESSION OK';
    }
  }

  String get lapDividerModeText {
    switch (lapDividerMode) {
      case LapDividerMode.geofence:
        return 'GEOFENCE';
      case LapDividerMode.distance:
        return 'DISTANCE';
      case LapDividerMode.none:
        return 'NONE';
    }
  }

  String get distanceLapDividerKmText {
    return '${distanceLapDividerKm.toStringAsFixed(2)} km';
  }

  String get gpsFallbackPeriodText {
    return '${(gpsFallbackPeriodMs / 1000.0).toStringAsFixed(1)} s';
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

  @visibleForTesting
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
      lapDividerMode: lapDividerMode,
      distanceLapDividerKm: distanceLapDividerKm,
      gpsFallbackPeriodMs: gpsFallbackPeriodMs,
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
    lapDividerMode = snapshot.lapDividerMode;
    distanceLapDividerKm = snapshot.distanceLapDividerKm
        .clamp(0.05, 10.0)
        .toDouble();
    gpsFallbackPeriodMs = snapshot.gpsFallbackPeriodMs
        .clamp(1000, 30000)
        .toInt();
    _nextDistanceDividerKm = null;
    if (!usingPhoneGpsFallback) {
      phoneGpsAccuracyM = null;
    }

    startBlockReason = null;
    endBlockReason = null;
    _applySessionControlState(snapshot.controlState);
    _lapBoundaryService.resetTracking();
    _lapBoundaryService.setDeadzone(
      Duration(milliseconds: crossingDeadzoneMs),
    );

    notifyListeners();
  }

  String get lastAlertSeverityText {
    return lastAlertSeverity?.wireValue ?? 'NONE';
  }

  String get alertVolumePercentText {
    return '${(alertVolume * 100).round()}%';
  }

  @visibleForTesting
  int get commandTerminalCount {
    return commandCompletionCount + commandRejectedCount;
  }

  @visibleForTesting
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

  // GENERATE NAME (e.g., RUN_20260327_1430)
  String generateDefaultName() {
    final now = DateTime.now();
    return "RUN_${DateFormat('yyyyMMdd_HHmm').format(now)}";
  }

  // START SESSION
  bool startSession(String name) {
    final resolvedName = name.isEmpty ? generateDefaultName() : name;
    _sessionId = const Uuid().v4();
    _sessionName = resolvedName;

    final armedControl = _sessionOrchestrator.arm(
      control: sessionControlState,
    );
    _applySessionControlState(armedControl);

    final decision = _sessionOrchestrator.requestStart(
      control: sessionControlState,
      speedKmh: speedKmh,
      nowUtc: DateTime.now().toUtc(),
    );

    if (!decision.accepted) {
      startBlockReason = decision.reason;
      notifyListeners();
      return false;
    }

    sessionTimeSeconds = 0;
    lapNumber = 1;
    _nextDistanceDividerKm = null;
    startBlockReason = null;
    endBlockReason = null;
    _applySessionControlState(decision.nextControl);
    notifyListeners();
    return true;
  }

  // STOP SESSION
  bool stopSession({bool abort = false}) {
    if (!abort &&
        _spoolHealth.requiresReplayDrainBeforeStop &&
        unsentBatchCount > 0) {
      endBlockReason =
          'Stop blocked until recovered-session replay backlog is drained.';
      notifyListeners();
      return false;
    }

    final decision = _sessionOrchestrator.requestStop(
      control: sessionControlState,
      nowUtc: DateTime.now().toUtc(),
      abort: abort,
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

  void setUiMode(UiMode mode) {
    if (_uiMode == mode) {
      return;
    }
    _uiMode = mode;
    notifyListeners();
  }

  @visibleForTesting
  void setLapsCompleted(int value) {
    final bounded = value.clamp(0, 9999);
    if (lapsCompleted == bounded) {
      return;
    }
    lapsCompleted = bounded;
    notifyListeners();
  }

  void setCrossingDeadzoneMs(int value) {
    final bounded = value.clamp(1000, 10000);
    if (crossingDeadzoneMs == bounded) {
      return;
    }
    crossingDeadzoneMs = bounded;
    _lapBoundaryService.setDeadzone(
      Duration(milliseconds: crossingDeadzoneMs),
    );
    if (crossingDeadzoneRemainingMs > crossingDeadzoneMs) {
      crossingDeadzoneRemainingMs = crossingDeadzoneMs;
    }
    notifyListeners();
  }

  void setLapDividerMode(LapDividerMode mode) {
    if (lapDividerMode == mode) {
      return;
    }
    lapDividerMode = mode;
    _nextDistanceDividerKm = null;
    if (lapDividerMode != LapDividerMode.geofence) {
      crossingDeadzoneRemainingMs = 0;
      if (_lapPhase == LapPhase.crossingDeadzone ||
          _lapPhase == LapPhase.crossingCandidate) {
        _lapPhase = LapPhase.running;
      }
    } else {
      _lapBoundaryService.resetTracking();
    }
    notifyListeners();
  }

  void setDistanceLapDividerKm(double value) {
    final bounded = value.clamp(0.05, 10.0).toDouble();
    if ((distanceLapDividerKm - bounded).abs() < 0.001) {
      return;
    }
    distanceLapDividerKm = bounded;
    _nextDistanceDividerKm = null;
    notifyListeners();
  }

  void setGpsFallbackPeriodMs(int value) {
    final bounded = value.clamp(1000, 30000).toInt();
    if (gpsFallbackPeriodMs == bounded) {
      return;
    }
    gpsFallbackPeriodMs = bounded;
    notifyListeners();
  }

  void _applySessionControlState(SessionControlState control) {
    _sessionControl.applyControlState(control);
  }

  void _handleSpoolHealthChanged() {
    notifyListeners();
  }

  void resetSessionState() {
    _sessionName = '';
    _sessionId = '';
    _sessionControl.reset();
    _spoolHealth.clearReplayDrainGate();
    startBlockReason = null;
    endBlockReason = null;
    lastCrossingReason = null;
    _nextDistanceDividerKm = null;
    _lapCrossings.clear();
    _lapBoundaryService.resetTracking();
    notifyListeners();
  }

  void configureLapBoundary({required GeoPoint start, required GeoPoint end}) {
    _lapBoundaryService.setFinishLine(start: start, end: end);
    _lapBoundaryService.setDeadzone(
      Duration(milliseconds: crossingDeadzoneMs),
    );
    _lapBoundaryConfigured = true;
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

    if (lat.abs() > 0.001 || lon.abs() > 0.001) {
      _gps.lastKnownLat = lat;
      _gps.lastKnownLon = lon;
    }

    if (lapDividerMode != LapDividerMode.geofence || !isLogging) {
      return;
    }

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
        lapNumber = max(1, lapsCompleted + 1);
        _recordLapCrossing(
          lapNumber: lapsCompleted,
          lat: lat,
          lon: lon,
          tsWallUtc: sampleTimestampUtc,
        );
        notifyListeners();
        return;
    }
  }

  // Pedal states
  double get throttlePercent => _metrics.throttlePercent;
  set throttlePercent(double value) => _metrics.throttlePercent = value;
  bool get isBrakePressed => _metrics.isBrakePressed;
  set isBrakePressed(bool value) => _metrics.isBrakePressed = value;

  // Aux states
  bool get leftTurn => _metrics.leftTurn;
  set leftTurn(bool value) => _metrics.leftTurn = value;
  bool get rightTurn => _metrics.rightTurn;
  set rightTurn(bool value) => _metrics.rightTurn = value;
  bool get headlights => _metrics.headlights;
  set headlights(bool value) => _metrics.headlights = value;
  bool get hazards => _metrics.hazards;
  set hazards(bool value) => _metrics.hazards = value;
  bool get horn => _metrics.horn;
  set horn(bool value) => _metrics.horn = value;
  bool get wipers => _metrics.wipers;
  set wipers(bool value) => _metrics.wipers = value;

  // Power & Environment
  double get mainVoltage => _metrics.mainVoltage;
  set mainVoltage(double value) => _metrics.mainVoltage = value;
  double get current780 => _metrics.current780;
  set current780(double value) => _metrics.current780 = value;
  double get mcTempC => _metrics.mcTempC;
  set mcTempC(double value) => _metrics.mcTempC = value;
  double get battTempC => _metrics.battTempC;
  set battTempC(double value) => _metrics.battTempC = value;

  // Energy
  double get energyJ780 => _metrics.energyJ780;
  set energyJ780(double value) => _metrics.energyJ780 = value;

  // Connections
  bool isConnected = false;
  bool isServerConnected = false;
  int get unsentBatchCount => _spoolHealth.pendingPublishCount;
  int get oldestUnsentAgeMs => _spoolHealth.oldestAgeMs;
  int get spoolPendingBatchCount => _spoolHealth.pendingBatchCount;
  int get spoolPendingBatchCapacity => _spoolHealth.pendingBatchCapacity;
  bool get spoolCapacityWarning => _spoolHealth.capacityWarning;
  @visibleForTesting
  int get recoveryResumeCount => _spoolHealth.recoveryResumeCount;
  @visibleForTesting
  DateTime? get lastRecoveryAtUtc => _spoolHealth.lastRecoveryAtUtc;
  bool enableSimulation = false;
  bool isSimulated = false;

  // EV Metrics
  double get speedKmh => _metrics.speedKmh;
  set speedKmh(double value) => _metrics.speedKmh = value;
  double get distanceKm => _metrics.distanceKm;
  set distanceKm(double value) => _metrics.distanceKm = value;
  int get lapNumber => _metrics.lapNumber;
  set lapNumber(int value) => _metrics.lapNumber = value;

  Queue<double> get _speedHistory => _metrics.speedHistory;
  Queue<double> get _powerKwHistory => _metrics.powerKwHistory;

  double get instKmPerKwh => _metrics.instKmPerKwh;
  set instKmPerKwh(double value) => _metrics.instKmPerKwh = value;
  double get avgKmPerKwh => _metrics.avgKmPerKwh;
  set avgKmPerKwh(double value) => _metrics.avgKmPerKwh = value;

  int get errorCount => _metrics.errorCount;
  set errorCount(int value) => _metrics.errorCount = value;
  String get lastErrorCode => _metrics.lastErrorCode;
  set lastErrorCode(String value) => _metrics.lastErrorCode = value;
  String get strategy => _metrics.strategy;
  set strategy(String value) => _metrics.strategy = value;

  int commandSentCount = 0;
  int commandCompletionCount = 0;
  int commandAckCount = 0;
  int commandRejectedCount = 0;

  bool get alertAudioEnabled => _alerts.alertAudioEnabled;
  set alertAudioEnabled(bool value) => _alerts.alertAudioEnabled = value;
  bool get alertHapticsEnabled => _alerts.alertHapticsEnabled;
  set alertHapticsEnabled(bool value) => _alerts.alertHapticsEnabled = value;
  bool get alertAdvisoryEnabled => _alerts.alertAdvisoryEnabled;
  set alertAdvisoryEnabled(bool value) => _alerts.alertAdvisoryEnabled = value;
  double get alertVolume => _alerts.alertVolume;
  set alertVolume(double value) => _alerts.alertVolume = value;
  int get alertCooldownMs => _alerts.alertCooldownMs;
  set alertCooldownMs(int value) => _alerts.alertCooldownMs = value;
  int get alertCriticalRepeatCount => _alerts.alertCriticalRepeatCount;
  set alertCriticalRepeatCount(int value) =>
      _alerts.alertCriticalRepeatCount = value;
  int get alertCriticalRepeatIntervalMs => _alerts.alertCriticalRepeatIntervalMs;
  set alertCriticalRepeatIntervalMs(int value) =>
      _alerts.alertCriticalRepeatIntervalMs = value;
  String get lastAlertCode => _alerts.lastAlertCode;
  set lastAlertCode(String value) => _alerts.lastAlertCode = value;
  String get lastAlertReasonClass => _alerts.lastAlertReasonClass;
  set lastAlertReasonClass(String value) =>
      _alerts.lastAlertReasonClass = value;
  DriverAlertSeverity? get lastAlertSeverity => _alerts.lastAlertSeverity;
  set lastAlertSeverity(DriverAlertSeverity? value) =>
      _alerts.lastAlertSeverity = value;
  DateTime? get lastAlertAtUtc => _alerts.lastAlertAtUtc;
  set lastAlertAtUtc(DateTime? value) => _alerts.lastAlertAtUtc = value;

  Map<AlertVariableKey, AlertVariableSettings> get alertVariables =>
      _alerts.alertVariables;

  void setAlertVariableEnabled(AlertVariableKey key, bool enabled) {
    final settings = _alerts.alertVariables[key];
    if (settings == null || settings.enabled == enabled) {
      return;
    }
    settings.enabled = enabled;
    notifyListeners();
  }

  void setAlertVariableMinThreshold(AlertVariableKey key, double value) {
    final settings = _alerts.alertVariables[key];
    if (settings == null || settings.minThreshold == value) {
      return;
    }
    settings.minThreshold = value;
    notifyListeners();
  }

  void setAlertVariableMaxThreshold(AlertVariableKey key, double value) {
    final settings = _alerts.alertVariables[key];
    if (settings == null || settings.maxThreshold == value) {
      return;
    }
    settings.maxThreshold = value;
    notifyListeners();
  }

  void setAlertVariableCue(AlertVariableKey key, AlertCue cue) {
    final settings = _alerts.alertVariables[key];
    if (settings == null || settings.cue == cue) {
      return;
    }
    settings.cue = cue;
    notifyListeners();
  }

  void applyAlertVariableSettings(
    AlertVariableKey key,
    AlertVariableSettings settings,
  ) {
    final current = _alerts.alertVariables[key];
    if (current == null) {
      return;
    }
    current.enabled = settings.enabled;
    current.minThreshold = settings.minThreshold;
    current.maxThreshold = settings.maxThreshold;
    notifyListeners();
  }

  double alertVariableValue(AlertVariableKey key) {
    switch (key) {
      case AlertVariableKey.voltage:
        return mainVoltage;
      case AlertVariableKey.current:
        return current780;
      case AlertVariableKey.power:
        return mainVoltage * current780;
      case AlertVariableKey.speed:
        return speedKmh;
      case AlertVariableKey.mcTemp:
        return mcTempC;
      case AlertVariableKey.battTemp:
        return battTempC;
      case AlertVariableKey.bmsMinCell:
        return bmsCells.isEmpty ? 0.0 : bmsCells.reduce(min);
      case AlertVariableKey.bus12V:
        return bus12V;
    }
  }

  int get readableCopyRetentionDays => _readableCopy.retentionDays;
  set readableCopyRetentionDays(int value) =>
      _readableCopy.retentionDays = value;
  int get readableCopyMaxFileBytes => _readableCopy.maxFileBytes;
  set readableCopyMaxFileBytes(int value) => _readableCopy.maxFileBytes = value;
  bool get readableCopyPreviewLoading => _readableCopy.previewLoading;
  set readableCopyPreviewLoading(bool value) =>
      _readableCopy.previewLoading = value;
  int get readableCopyFileCount => _readableCopy.fileCount;
  set readableCopyFileCount(int value) => _readableCopy.fileCount = value;
  String? get readableCopyDirectoryPath => _readableCopy.directoryPath;
  set readableCopyDirectoryPath(String? value) =>
      _readableCopy.directoryPath = value;
  String? get readableCopyPreviewError => _readableCopy.previewError;
  set readableCopyPreviewError(String? value) =>
      _readableCopy.previewError = value;
  String? get readableCopyLastExportPath => _readableCopy.lastExportPath;
  set readableCopyLastExportPath(String? value) =>
      _readableCopy.lastExportPath = value;
  DateTime? get readableCopyLastUpdatedAtUtc => _readableCopy.lastUpdatedAtUtc;
  set readableCopyLastUpdatedAtUtc(DateTime? value) =>
      _readableCopy.lastUpdatedAtUtc = value;
  Queue<String> get readableCopyRecentLines => _readableCopy.recentLines;

  Future<ReadableLocalCopyPreview> Function()?
  get onRequestReadableCopyPreview => _readableCopy.onRequestPreview;
  set onRequestReadableCopyPreview(
    Future<ReadableLocalCopyPreview> Function()? value,
  ) => _readableCopy.onRequestPreview = value;
  Future<String?> Function()? get onRequestReadableCopyExport =>
      _readableCopy.onRequestExport;
  set onRequestReadableCopyExport(Future<String?> Function()? value) =>
      _readableCopy.onRequestExport = value;
  Future<void> Function(int retentionDays)?
  get onReadableCopyRetentionDaysChanged =>
      _readableCopy.onRetentionDaysChanged;
  set onReadableCopyRetentionDaysChanged(
    Future<void> Function(int retentionDays)? value,
  ) => _readableCopy.onRetentionDaysChanged = value;
  Future<void> Function(int maxFileBytes)?
  get onReadableCopyMaxFileBytesChanged => _readableCopy.onMaxFileBytesChanged;
  set onReadableCopyMaxFileBytesChanged(
    Future<void> Function(int maxFileBytes)? value,
  ) => _readableCopy.onMaxFileBytesChanged = value;
  void Function(bool enabled)? onSimulationToggleChanged;

  Future<TxCommandResult> Function(TxCanCommand command)? onTxCommand;

  // Debug & Engineer screen
  Map<int, String> get lastCanPayloads => _metrics.lastCanPayloads;
  List<double> get bmsCells => _metrics.bmsCells;
  set bmsCells(List<double> value) => _metrics.bmsCells = value;
  double get bus12V => _metrics.bus12V;
  set bus12V(double value) => _metrics.bus12V = value;
  List<String> get mcFaults => _metrics.mcFaults;
  set mcFaults(List<String> value) => _metrics.mcFaults = value;

  // GPS
  int get gpsSatellites => _gps.gpsSatellites;
  set gpsSatellites(int value) => _gps.gpsSatellites = value;
  bool get gpsLocked => _gps.gpsLocked;
  set gpsLocked(bool value) => _gps.gpsLocked = value;
  bool get usingPhoneGpsFallback => _gps.usingPhoneGpsFallback;
  set usingPhoneGpsFallback(bool value) => _gps.usingPhoneGpsFallback = value;
  double? get currentGpsLat => _gps.currentGpsLat;
  set currentGpsLat(double? value) => _gps.currentGpsLat = value;
  double? get currentGpsLon => _gps.currentGpsLon;
  set currentGpsLon(double? value) => _gps.currentGpsLon = value;
  double? get currentGpsHeadingDeg => _gps.currentGpsHeadingDeg;
  set currentGpsHeadingDeg(double? value) => _gps.currentGpsHeadingDeg = value;
  double? get currentGpsSpeedKmh => _gps.currentGpsSpeedKmh;
  set currentGpsSpeedKmh(double? value) => _gps.currentGpsSpeedKmh = value;
  DateTime? get currentGpsSampleAtUtc => _gps.currentGpsSampleAtUtc;
  set currentGpsSampleAtUtc(DateTime? value) =>
      _gps.currentGpsSampleAtUtc = value;
  String? get currentGpsSource => _gps.currentGpsSource;
  set currentGpsSource(String? value) => _gps.currentGpsSource = value;
  bool get notificationPermissionGranted => _gps.notificationPermissionGranted;
  set notificationPermissionGranted(bool value) =>
      _gps.notificationPermissionGranted = value;
  bool get backgroundLocationPermissionGranted =>
      _gps.backgroundLocationPermissionGranted;
  set backgroundLocationPermissionGranted(bool value) =>
      _gps.backgroundLocationPermissionGranted = value;
  double? get phoneGpsAccuracyM => _gps.phoneGpsAccuracyM;
  set phoneGpsAccuracyM(double? value) => _gps.phoneGpsAccuracyM = value;
  double? get lastKnownLat => _gps.lastKnownLat;
  set lastKnownLat(double? value) {
    if (_gps.lastKnownLat == value) return;
    _gps.lastKnownLat = value;
    notifyListeners();
  }
  double? get lastKnownLon => _gps.lastKnownLon;
  set lastKnownLon(double? value) {
    if (_gps.lastKnownLon == value) return;
    _gps.lastKnownLon = value;
    notifyListeners();
  }
  DateTime get _lastExternalGpsMessageAt => _gps.lastExternalGpsMessageAt;
  set _lastExternalGpsMessageAt(DateTime value) =>
      _gps.lastExternalGpsMessageAt = value;

  bool get isExternalGpsStale {
    return DateTime.now().difference(_lastExternalGpsMessageAt) >
        Duration(milliseconds: gpsFallbackPeriodMs);
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
  List<double> get throttleMap => _config.throttleMap;
  set throttleMap(List<double> value) => _config.throttleMap = value;
  List<double> get throttleMapDraft => _config.throttleMapDraft;
  set throttleMapDraft(List<double> value) => _config.throttleMapDraft = value;
  String get selectedThrottleMapProfile => _config.selectedThrottleMapProfile;
  set selectedThrottleMapProfile(String value) =>
      _config.selectedThrottleMapProfile = value;
  Map<String, List<double>> get _throttleMapPresets =>
      _config.throttleMapPresets;

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
  bool get useLightTheme => _config.useLightTheme;
  set useLightTheme(bool value) => _config.useLightTheme = value;
  bool get useDictionaryAuxDispatch => _config.useDictionaryAuxDispatch;
  set useDictionaryAuxDispatch(bool value) =>
      _config.useDictionaryAuxDispatch = value;

  // Speed bar thresholds
  double get speedUpperThreshold => _config.speedUpperThreshold;
  set speedUpperThreshold(double value) => _config.speedUpperThreshold = value;
  double get speedLowerThreshold => _config.speedLowerThreshold;
  set speedLowerThreshold(double value) => _config.speedLowerThreshold = value;

  void Function(String)? onUsbTx;

  Future<void> Function()? onRequestMqttSpoolReset;
  Future<void> Function()? onRequestLocalStorageClear;

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
        break;
      case TxCommandStatus.timeout:
        commandCompletionCount += 1;
        break;
      case TxCommandStatus.rejected:
        commandRejectedCount += 1;
        break;
    }

    notifyListeners();
  }

  // Session timer
  late final _SessionTicker _sessionTicker;

  DashboardState({Duration externalGpsTimeout = const Duration(seconds: 5)}) {
    _spoolHealth.addListener(_handleSpoolHealthChanged);

    final initialFallbackPeriodMs = externalGpsTimeout.inMilliseconds;
    gpsFallbackPeriodMs = initialFallbackPeriodMs <= 0
        ? 5000
        : initialFallbackPeriodMs.clamp(1, 30000).toInt();

    _sessionTicker = _SessionTicker(
      sessionControl: _sessionControl,
      onTick: notifyListeners,
    );
    _sessionTicker.start();
  }

  @override
  void dispose() {
    _sessionTicker.stop();
    _spoolHealth.removeListener(_handleSpoolHealthChanged);
    if (_ownsSpoolHealth) {
      _spoolHealth.dispose();
    }
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

  void resetTelemetry() {
    throttlePercent = 0;
    isBrakePressed = false;
    mainVoltage = 0;
    current780 = 0;
    mcTempC = 45.0;
    battTempC = 35.0;
    energyJ780 = 0;
    speedKmh = 0;
    distanceKm = 0;
    instKmPerKwh = 0;
    avgKmPerKwh = 0;
    errorCount = 0;
    lastErrorCode = 'OK';
    strategy = 'PACE';
    bmsCells = List.filled(24, 3.80);
    bus12V = 12.4;
    _speedHistory.clear();
    _powerKwHistory.clear();
    gpsSatellites = 0;
    gpsLocked = false;
    usingPhoneGpsFallback = false;
    phoneGpsAccuracyM = null;
    if (!isLogging) {
      sessionTimeSeconds = 0;
      lapNumber = 0;
    }
    notifyListeners();
  }

  void clearCurrentState() {
    resetTelemetry();
    resetSessionState();
    lastCanPayloads.clear();
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
    final callback = _alerts.onRequestAlertTestTone;
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

  @visibleForTesting
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
    _alerts.lastAlertCode = alertCode;
    _alerts.lastAlertSeverity = severity;
    _alerts.lastAlertReasonClass = reasonClass ?? 'NONE';
    _alerts.lastAlertAtUtc = (atUtc ?? DateTime.now().toUtc()).toUtc();

    notifyListeners();
  }

  void updateSpeedThresholds(double lower, double upper) {
    speedLowerThreshold = lower;
    speedUpperThreshold = upper;
    notifyListeners();
  }

  void setServerConnectionState(bool state) {
    if (isServerConnected != state) {
      isServerConnected = state;
      notifyListeners();
    }
  }

  @visibleForTesting
  void updateMqttBacklog({
    required int count,
    required DateTime? oldestEnqueuedAtUtc,
  }) {
    _spoolHealth.updateBacklog(
      count: count,
      oldestEnqueuedAtUtc: oldestEnqueuedAtUtc,
    );
  }

  @visibleForTesting
  void updateSpoolHealth({
    required int pendingBatchCount,
    required int pendingBatchCapacity,
  }) {
    _spoolHealth.updatePendingCapacity(
      pendingBatchCount: pendingBatchCount,
      pendingBatchCapacity: pendingBatchCapacity,
    );
  }

  @visibleForTesting
  void recordRecoveryResume({DateTime? atUtc}) {
    _spoolHealth.recordRecoveryResume(atUtc: atUtc);
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

  void updateDashStatus(DashStatusPayload payload) {
    errorCount = payload.errorCount;
    lastErrorCode = payload.lastErrorCode;
    strategy = payload.strategy;
    mcTempC = payload.mcTempC;
    battTempC = payload.battTempC;
    notifyListeners();
  }

  @visibleForTesting
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

  void updatePhoneGpsFallback({
    required bool locked,
    double? accuracyM,
    int? satellites,
  }) {
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

    gpsLocked = locked;
    if (satellites != null) {
      gpsSatellites = satellites;
    }
    usingPhoneGpsFallback = true;
    phoneGpsAccuracyM = boundedAccuracy;

    if (changed) {
      notifyListeners();
    }
  }

  void updatePedal(PedalPayload payload) {
    throttlePercent = payload.throttlePercent;
    isBrakePressed = payload.isBrakePressed;
    notifyListeners();
  }

  void updateAux(AuxControlPayload payload) {
    leftTurn = payload.leftTurn;
    rightTurn = payload.rightTurn;
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
    }
    _updateEfficiency();
    notifyListeners();
  }

  void updateEnergy(EnergyPayload payload) {
    energyJ780 = payload.joules780;
    notifyListeners();
  }

  @visibleForTesting
  void updateErrorCount(int count) {
    errorCount = count;
    notifyListeners();
  }

  @visibleForTesting
  void updateStrategy(String str) {
    strategy = str;
    notifyListeners();
  }

  void updateMotion(double speed, double distance, int lap) {
    speedKmh = speed;
    distanceKm = distance;
    lapNumber = lap;

    if (_isLogging && lapDividerMode == LapDividerMode.distance) {
      _applyDistanceLapDivider(distanceKm);
    }

    _updateEfficiency();
    notifyListeners();
  }

  void _applyDistanceLapDivider(double cumulativeDistanceKm) {
    final dividerKm = distanceLapDividerKm;
    if (dividerKm <= 0) {
      return;
    }

    final nextDivider = _nextDistanceDividerKm;
    if (nextDivider == null) {
      _nextDistanceDividerKm = cumulativeDistanceKm + dividerKm;
      return;
    }

    final resetThresholdKm = nextDivider - (dividerKm * 1.25);
    if (cumulativeDistanceKm < resetThresholdKm) {
      _nextDistanceDividerKm = cumulativeDistanceKm + dividerKm;
      return;
    }

    var cursor = nextDivider;
    while (cumulativeDistanceKm >= cursor) {
      _applyDividerLapAccepted();
      cursor += dividerKm;
    }
    _nextDistanceDividerKm = cursor;
  }

  void _applyDividerLapAccepted() {
    final nextLapsCompleted = lapsCompleted + 1;
    final nextControl = sessionControlState.copyWith(
      lapsCompleted: nextLapsCompleted,
      lapPhase: LapPhase.running,
      crossingValid: true,
      crossingDeadzoneRemainingMs: 0,
    );
    _applySessionControlState(nextControl);
    lapNumber = max(1, lapsCompleted + 1);
    lastCrossingReason = null;
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
  }
}
