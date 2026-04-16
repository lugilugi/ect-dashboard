import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/session_models.dart';
import '../providers/dashboard_state.dart';
import 'local_spool_service.dart';
import 'mqtt_service.dart';

class SessionCheckpointService {
  final DashboardState _state;
  final LocalSpoolService _localSpoolService;
  final MqttService _mqttService;
  final Duration checkpointInterval;

  Timer? _timer;
  bool _started = false;
  bool _writeInFlight = false;
  bool _pendingSync = false;
  bool _restoreApplied = false;

  SessionCheckpointService({
    required DashboardState state,
    required LocalSpoolService localSpoolService,
    required MqttService mqttService,
    this.checkpointInterval = const Duration(seconds: 1),
  }) : _state = state,
       _localSpoolService = localSpoolService,
       _mqttService = mqttService;

  bool get restoreApplied => _restoreApplied;

  Future<void> start() async {
    if (_started) {
      return;
    }

    _started = true;
    await _localSpoolService.initialize();
    await _restoreCheckpointIfPresent();

    _state.addListener(_onStateChanged);
    _timer = Timer.periodic(checkpointInterval, (_) {
      unawaited(_persistIfNeeded());
    });

    unawaited(_persistIfNeeded());
  }

  void stop() {
    if (!_started) {
      return;
    }

    _started = false;
    _timer?.cancel();
    _timer = null;
    _state.removeListener(_onStateChanged);
  }

  void _onStateChanged() {
    unawaited(_persistIfNeeded());
  }

  bool get _sessionActive {
    return _state.sessionState == SessionState.armed ||
        _state.sessionState == SessionState.logging;
  }

  Future<void> _persistIfNeeded() async {
    if (!_started) {
      return;
    }

    if (_writeInFlight) {
      _pendingSync = true;
      return;
    }

    _writeInFlight = true;
    _pendingSync = false;
    try {
      if (_sessionActive) {
        if (_state.sessionId.isEmpty) {
          return;
        }

        final snapshot = _state.buildSessionCheckpointSnapshot(
          lastSeqInSession: _mqttService.sequenceForCheckpoint,
        );
        await _localSpoolService.saveSessionCheckpoint(
          checkpointJson: jsonEncode(snapshot.toJson()),
          updatedAtUtc: snapshot.updatedAtUtc,
        );
        return;
      }

      await _localSpoolService.clearSessionCheckpoint();
    } finally {
      _writeInFlight = false;
      if (_pendingSync && _started) {
        _pendingSync = false;
        unawaited(_persistIfNeeded());
      }
    }
  }

  Future<void> _restoreCheckpointIfPresent() async {
    final checkpointJson = await _localSpoolService.readSessionCheckpointJson();
    if (checkpointJson == null || checkpointJson.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(checkpointJson) as Map<String, dynamic>;
      final snapshot = SessionCheckpointSnapshot.fromJson(decoded);
      final recoverable =
          snapshot.sessionState == SessionState.logging ||
          snapshot.sessionState == SessionState.armed;

      if (!recoverable || snapshot.sessionId.isEmpty) {
        await _localSpoolService.clearSessionCheckpoint();
        return;
      }

      final spoolMaxSeq = await _localSpoolService
          .maxDecodedSequenceForSession(snapshot.sessionId);
      final recoveredSeqInSession = math.max(
        snapshot.lastSeqInSession,
        spoolMaxSeq,
      );

      _state.restoreFromCheckpoint(snapshot);
      _state.recordRecoveryResume();
      _mqttService.restoreSessionSequenceFromCheckpoint(
        sessionId: snapshot.sessionId,
        lastSeqInSession: recoveredSeqInSession,
      );
      _mqttService.publishRecoveryDiagnostic(
        recoveredSessionId: snapshot.sessionId,
        recoveredSeqInSession: recoveredSeqInSession,
      );
      _restoreApplied = true;
    } catch (e) {
      debugPrint('Session checkpoint restore failed, clearing checkpoint: $e');
      await _localSpoolService.clearSessionCheckpoint();
    }
  }
}
