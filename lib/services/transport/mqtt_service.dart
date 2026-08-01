import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:uuid/uuid.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_payload_contract.dart';

abstract class MqttTransport {
  Future<void> connect();
  void disconnect();
  bool get isConnected;

  bool publish({required String topic, required String payloadJson});

  set onConnected(void Function()? callback);
  set onDisconnected(void Function()? callback);
}

class MqttServerClientTransport implements MqttTransport {
  final MqttServerClient _client;
  void Function()? _onConnected;
  void Function()? _onDisconnected;

  MqttServerClientTransport({
    required String host,
    required String clientId,
    int port = 1883,
    int keepAliveSeconds = 20,
    bool autoReconnect = true,
  }) : _client = MqttServerClient(host, clientId) {
    _client.port = port;
    _client.logging(on: false);
    _client.keepAlivePeriod = keepAliveSeconds;
    _client.autoReconnect = autoReconnect;
    _client.onConnected = () {
      _onConnected?.call();
    };
    _client.onDisconnected = () {
      _onDisconnected?.call();
    };
  }

  @override
  set onConnected(void Function()? callback) {
    _onConnected = callback;
  }

  @override
  set onDisconnected(void Function()? callback) {
    _onDisconnected = callback;
  }

  @override
  Future<void> connect() {
    return _client.connect();
  }

  @override
  void disconnect() {
    _client.disconnect();
  }

  @override
  bool get isConnected {
    return _client.connectionStatus?.state == MqttConnectionState.connected;
  }

  @override
  bool publish({required String topic, required String payloadJson}) {
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(payloadJson);
      _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _PendingPublish {
  final int spoolBatchId;
  final String topic;
  final String payloadJson;
  final DateTime enqueuedAtUtc;
  final String? sessionId;
  final int? seqInSessionStart;
  final int? seqInSessionEnd;

  _PendingPublish({
    required this.spoolBatchId,
    required this.topic,
    required this.payloadJson,
    required this.enqueuedAtUtc,
    required this.sessionId,
    required this.seqInSessionStart,
    required this.seqInSessionEnd,
  });
}

class MqttService {
  final DashboardState state;
  final LocalSpoolService _localSpoolService;
  final Duration mqttRetryInterval;
  MqttTransport _transport;
  int _seqInSession = 0;
  String _lastSessionId = '';
  final ListQueue<_PendingPublish> _pendingPublishes = ListQueue();
  final ListQueue<DecodedMetricEvent> _canonicalEventBuffer = ListQueue();
  final Map<String, double> _lastPublishedValues = {};
  Timer? _flushTimer;
  Timer? _reconnectTimer;
  bool _connecting = false;
  bool _isFlushingCanonicalBuffer = false;

  String? _lastSentSessionId;
  String? _lastSentSessionName;
  SessionState? _lastSentSessionState;
  UiMode? _lastSentUiMode;
  int? _lastSentLapsCompleted;
  int? _lastSentCrossingDeadzoneMs;

  static const int maxPendingPublishes = 2000;
  static const int maxBatchEvents = 32;
  static const int maxBatchPayloadBytes = 32 * 1024;
  static const Duration canonicalFlushInterval = Duration(milliseconds: 200);

  static const String canonicalTopic = 'telemetry/eco_archers/events';

  // Generates a unique ID every time the app opens or the user hits "Start Session"
  final String currentSessionId = const Uuid().v4();

  String? _currentConnectedHost;

  MqttService(
    this.state, {
    LocalSpoolService? localSpoolService,
    MqttTransport? transport,
    this.mqttRetryInterval = const Duration(seconds: 5),
  }) : _localSpoolService = localSpoolService ?? LocalSpoolService(),
       _transport =
           transport ??
           MqttServerClientTransport(
             host: state.mqttHost,
             clientId: 'eco_archers_car',
           ) {
    if (transport == null) {
      _currentConnectedHost = state.mqttHost;
    }
    _setupCallbacks();
  }

  void publishSessionMetadata() {
    if (_transport is MqttServerClientTransport &&
        _currentConnectedHost != null &&
        _currentConnectedHost != state.mqttHost) {
      unawaited(_reconnectWithNewHost(state.mqttHost));
    }

    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return;

    final sessionName = state.sessionName;
    final sessionState = state.sessionState;
    final uiMode = state.uiMode;
    final lapsCompleted = state.lapsCompleted;
    final crossingDeadzoneMs = state.crossingDeadzoneMs;

    if (_lastSentSessionId == sessionId &&
        _lastSentSessionName == sessionName &&
        _lastSentSessionState == sessionState &&
        _lastSentUiMode == uiMode &&
        _lastSentLapsCompleted == lapsCompleted &&
        _lastSentCrossingDeadzoneMs == crossingDeadzoneMs) {
      return;
    }

    final payload = {
      'uid': sessionId,
      'session_name': sessionName,
      'vehicle_setup': jsonEncode({
        'session_state': sessionState.wireValue,
        'ui_mode': uiMode.wireValue,
        'laps_completed': lapsCompleted,
        'crossing_deadzone_ms': crossingDeadzoneMs,
      }),
    };

    unawaited(
      _publishSessionMetadataHandOff(
        sessionId: sessionId,
        sessionName: sessionName,
        sessionState: sessionState,
        uiMode: uiMode,
        lapsCompleted: lapsCompleted,
        crossingDeadzoneMs: crossingDeadzoneMs,
        payloadJson: jsonEncode(payload),
      ),
    );
  }

  // The _lastSent* dedup cache is updated only when the metadata was actually
  // handed off (published directly or durably queued to the spool). If the
  // handoff fails, the cache stays stale so the next attempt - or the
  // reconnect hook in _setupCallbacks - re-publishes it instead of silently
  // dropping the session metadata.
  Future<void> _publishSessionMetadataHandOff({
    required String sessionId,
    required String sessionName,
    required SessionState sessionState,
    required UiMode uiMode,
    required int lapsCompleted,
    required int crossingDeadzoneMs,
    required String payloadJson,
  }) async {
    final handedOff = await _publishOrQueue(
      topic: 'telemetry/eco_archers/sessions',
      payloadJson: payloadJson,
    );
    if (!handedOff) {
      return;
    }

    _lastSentSessionId = sessionId;
    _lastSentSessionName = sessionName;
    _lastSentSessionState = sessionState;
    _lastSentUiMode = uiMode;
    _lastSentLapsCompleted = lapsCompleted;
    _lastSentCrossingDeadzoneMs = crossingDeadzoneMs;
  }

  Future<void> _reconnectWithNewHost(String newHost) async {
    debugPrint('MQTT Host changed from $_currentConnectedHost to $newHost. Reconnecting...');
    _currentConnectedHost = newHost;
    _flushTimer?.cancel();
    _flushTimer = null;
    _transport.disconnect();
    _transport = MqttServerClientTransport(
      host: newHost,
      clientId: 'eco_archers_car',
    );
    _setupCallbacks();
    _startFlushTimer();
    try {
      await _transport.connect();
      if (_transport.isConnected) {
        debugPrint('MQTT Connected to $newHost!');
        state.setServerConnectionState(true);
        await _flushPendingPublishes();
        await _flushCanonicalEventBuffer(drainAll: true);
      }
    } catch (e) {
      debugPrint('MQTT Connection to $newHost failed: $e');
      _transport.disconnect();
      state.setServerConnectionState(false);
    }
  }

  Future<void> start() async {
    state.removeListener(publishSessionMetadata);
    state.addListener(publishSessionMetadata);
    publishSessionMetadata();

    await _localSpoolService.initialize();
    await _localSpoolService.prunePublishedOlderThan(const Duration(days: 7));
    await _localSpoolService.prunePublishedDecodedEventsOlderThan(
      const Duration(days: 7),
    );
    final readableRetentionDays = state.readableCopyRetentionDays.clamp(1, 30);
    await _localSpoolService.pruneReadableCopyOlderThan(
      Duration(days: readableRetentionDays),
    );
    await _hydratePendingPublishesFromSpool();
    _startFlushTimer();

    unawaited(_connectOnce());
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(mqttRetryInterval, (_) {
      if (!_isConnected && !_connecting) {
        unawaited(_connectOnce());
      }
    });
  }

  // Attempts an MQTT connection. On failure it simply returns - the periodic
  // retry timer keeps trying until the broker (or the network) comes back,
  // so a cold broker or a late Wi-Fi join no longer leaves the app offline
  // until restart.
  Future<void> _connectOnce() async {
    if (_connecting) {
      return;
    }
    _connecting = true;
    try {
      if (_isConnected) {
        return;
      }
      debugPrint('Connecting to MQTT (${state.mqttHost})...');
      await _transport.connect();
      if (_transport.isConnected) {
        debugPrint('MQTT Connected!');
        state.setServerConnectionState(true);
        await _flushPendingPublishes();
        await _flushCanonicalEventBuffer(drainAll: true);
      }
    } catch (e) {
      debugPrint('MQTT Connection Failed: $e');
      _transport.disconnect();
      state.setServerConnectionState(false);
    } finally {
      _connecting = false;
    }
  }

  void stop() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    state.removeListener(publishSessionMetadata);
    unawaited(_flushCanonicalEventBuffer(drainAll: true));
    _flushTimer?.cancel();
    _flushTimer = null;
    _transport.disconnect();
    state.setServerConnectionState(false);
  }

  String get _activeSessionId {
    return state.sessionId.isEmpty ? currentSessionId : state.sessionId;
  }

  void _prepareSequenceForActiveSession() {
    final activeSessionId = _activeSessionId;
    if (_lastSessionId == activeSessionId) {
      return;
    }

    if (_lastSessionId.isNotEmpty && _canonicalEventBuffer.isNotEmpty) {
      unawaited(_flushCanonicalEventBuffer(drainAll: true));
    }

    _lastSessionId = activeSessionId;
    _seqInSession = 0;
  }

  DecodedMetricEvent _buildDecodedMetricEvent({
    required String metricName,
    required double value,
    String source = 'can',
    String? unit,
    int? canId,
  }) {
    _prepareSequenceForActiveSession();
    _seqInSession += 1;

    return DecodedMetricEvent(
      metricKey: metricName,
      value: value,
      unit: unit,
      sessionId: _activeSessionId,
      lapNumber: state.lapNumber,
      sessionState: state.sessionState,
      lapPhase: state.lapPhase,
      tsWallUtc: DateTime.now().toUtc(),
      tsSessionMs: state.sessionTimeSeconds * 1000,
      source: source,
      canId: canId,
      seqInSession: _seqInSession,
      qualityFlag: 'ok',
    );
  }

  TelemetryEventBatchPayload _buildBatchPayload({
    required List<DecodedMetricEvent> events,
  }) {
    final sessionId = events.isEmpty
        ? _activeSessionId
        : events.first.sessionId;
    return TelemetryEventBatchPayload(
      schemaVersion: telemetryEventSchemaVersion,
      batchId: const Uuid().v4(),
      sessionId: sessionId,
      sessionState: state.sessionControlState.sessionState,
      createdAtUtc: DateTime.now().toUtc(),
      lapsCompleted: state.sessionControlState.lapsCompleted,
      events: events,
    );
  }

  @visibleForTesting
  TelemetryEventBatchPayload buildCanonicalBatchContract({
    required String metricName,
    required double value,
    String source = 'can',
    String? unit,
    int? canId,
  }) {
    final event = _buildDecodedMetricEvent(
      metricName: metricName,
      value: value,
      source: source,
      unit: unit,
      canId: canId,
    );

    return _buildBatchPayload(events: [event]);
  }

  void _setupCallbacks() {
    _transport.onConnected = () {
      state.setServerConnectionState(true);
      unawaited(_hydratePendingPublishesFromSpool());
      unawaited(_flushPendingPublishes());
      unawaited(_flushCanonicalEventBuffer(drainAll: true));
      // Re-publishes session metadata if the previous attempt was never
      // handed off (e.g. the spool was unavailable). Deduped otherwise.
      publishSessionMetadata();
    };

    _transport.onDisconnected = () {
      state.setServerConnectionState(false);
    };
  }

  bool get _isConnected {
    return _transport.isConnected;
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(canonicalFlushInterval, (_) {
      if (_canonicalEventBuffer.isNotEmpty) {
        unawaited(_flushCanonicalEventBuffer(drainAll: true));
      }
    });
  }

  Future<bool> _publishOrQueue({
    required String topic,
    required String payloadJson,
    String? sessionId,
    int? seqInSessionStart,
    int? seqInSessionEnd,
  }) async {
    try {
      if (_isConnected) {
        await _flushPendingPublishes();
        if (_publishDirect(topic: topic, payloadJson: payloadJson)) {
          return true;
        }
      }

      await _enqueuePending(
        topic: topic,
        payloadJson: payloadJson,
        sessionId: sessionId,
        seqInSessionStart: seqInSessionStart,
        seqInSessionEnd: seqInSessionEnd,
      );
      return true;
    } catch (e) {
      debugPrint('MQTT publish/queue failed, message not handed off: $e');
      return false;
    }
  }

  bool _publishDirect({required String topic, required String payloadJson}) {
    try {
      final sent = _transport.publish(topic: topic, payloadJson: payloadJson);
      if (!sent) {
        debugPrint('MQTT publish failed, buffering payload.');
      }
      return sent;
    } catch (e) {
      debugPrint('MQTT publish failed, buffering payload: $e');
      return false;
    }
  }

  Future<void> _enqueuePending({
    required String topic,
    required String payloadJson,
    String? sessionId,
    int? seqInSessionStart,
    int? seqInSessionEnd,
  }) async {
    final enqueuedAtUtc = DateTime.now().toUtc();
    final spoolBatchId = await _localSpoolService.enqueueBatch(
      topic: topic,
      payloadJson: payloadJson,
      enqueuedAtUtc: enqueuedAtUtc,
      sessionId: sessionId,
      seqInSessionStart: seqInSessionStart,
      seqInSessionEnd: seqInSessionEnd,
    );

    if (_pendingPublishes.length >= maxPendingPublishes) {
      final dropped = _pendingPublishes.removeFirst();
      await _localSpoolService.recordAttempt(
        batchId: dropped.spoolBatchId,
        outcome: 'dropped_in_memory_overflow',
        incrementAttemptCounter: false,
      );
      await _localSpoolService.markPublished(batchId: dropped.spoolBatchId);
      if (dropped.sessionId != null &&
          dropped.seqInSessionStart != null &&
          dropped.seqInSessionEnd != null) {
        await _localSpoolService.markDecodedEventsPublishedRange(
          sessionId: dropped.sessionId!,
          seqInSessionStart: dropped.seqInSessionStart!,
          seqInSessionEnd: dropped.seqInSessionEnd!,
        );
      }
    }

    _pendingPublishes.addLast(
      _PendingPublish(
        spoolBatchId: spoolBatchId,
        topic: topic,
        payloadJson: payloadJson,
        enqueuedAtUtc: enqueuedAtUtc,
        sessionId: sessionId,
        seqInSessionStart: seqInSessionStart,
        seqInSessionEnd: seqInSessionEnd,
      ),
    );
    _syncSpoolWarningState();
    _syncBacklogState();
  }

  Future<void> _flushPendingPublishes() async {
    if (!_isConnected || _pendingPublishes.isEmpty) {
      return;
    }

    while (_pendingPublishes.isNotEmpty && _isConnected) {
      final pending = _pendingPublishes.first;
      final sent = _publishDirect(
        topic: pending.topic,
        payloadJson: pending.payloadJson,
      );
      if (!sent) {
        await _localSpoolService.recordAttempt(
          batchId: pending.spoolBatchId,
          outcome: 'send_failed',
          errorReason: 'publish_direct_failed',
        );
        break;
      }

      await _localSpoolService.recordAttempt(
        batchId: pending.spoolBatchId,
        outcome: 'sent',
      );
      await _localSpoolService.markPublished(batchId: pending.spoolBatchId);
      if (pending.sessionId != null &&
          pending.seqInSessionStart != null &&
          pending.seqInSessionEnd != null) {
        await _localSpoolService.markDecodedEventsPublishedRange(
          sessionId: pending.sessionId!,
          seqInSessionStart: pending.seqInSessionStart!,
          seqInSessionEnd: pending.seqInSessionEnd!,
        );
      }
      _pendingPublishes.removeFirst();
    }

    _syncSpoolWarningState();
    _syncBacklogState();
  }

  void _syncBacklogState() {
    final oldestPending = _pendingPublishes.isEmpty
        ? null
        : _pendingPublishes.first.enqueuedAtUtc;
    final oldestBuffered = _canonicalEventBuffer.isEmpty
        ? null
        : _canonicalEventBuffer.first.tsWallUtc;

    DateTime? oldest;
    if (oldestPending == null) {
      oldest = oldestBuffered;
    } else if (oldestBuffered == null) {
      oldest = oldestPending;
    } else {
      oldest = oldestPending.isBefore(oldestBuffered)
          ? oldestPending
          : oldestBuffered;
    }

    _localSpoolService.spoolHealth.updateBacklog(
      count: _pendingPublishes.length + (_canonicalEventBuffer.isEmpty ? 0 : 1),
      oldestEnqueuedAtUtc: oldest,
    );
  }

  List<DecodedMetricEvent> _drainCanonicalChunk() {
    if (_canonicalEventBuffer.isEmpty) {
      return const [];
    }

    final chunk = <DecodedMetricEvent>[];

    for (final event in _canonicalEventBuffer) {
      chunk.add(event);

      final payload = _buildBatchPayload(events: chunk);
      final payloadSizeBytes = utf8.encode(jsonEncode(payload.toJson())).length;

      if (payloadSizeBytes > maxBatchPayloadBytes) {
        if (chunk.length > 1) {
          chunk.removeLast();
        }
        break;
      }

      if (chunk.length >= maxBatchEvents) {
        break;
      }
    }

    if (chunk.isEmpty) {
      return const [];
    }

    for (int i = 0; i < chunk.length; i++) {
      _canonicalEventBuffer.removeFirst();
    }
    return chunk;
  }

  Future<void> _flushCanonicalEventBuffer({bool drainAll = false}) async {
    if (_isFlushingCanonicalBuffer || _canonicalEventBuffer.isEmpty) {
      _syncBacklogState();
      return;
    }

    _isFlushingCanonicalBuffer = true;
    try {
      do {
        final chunk = _drainCanonicalChunk();
        if (chunk.isEmpty) {
          break;
        }

        final Map<String, dynamic> sparsePayload = {
          'session_uid': chunk.first.sessionId,
          'lap_number': chunk.first.lapNumber,
          'ts_wall_utc': chunk.first.tsWallUtc.toUtc().toIso8601String(),
          'ts_session_ms': chunk.first.tsSessionMs,
          'seq_in_session_start': chunk.first.seqInSession,
          'seq_in_session_end': chunk.last.seqInSession,
        };
        for (final event in chunk) {
          sparsePayload[event.metricKey] = event.value;
        }

        await _publishOrQueue(
          topic: canonicalTopic,
          payloadJson: jsonEncode(sparsePayload),
          sessionId: chunk.first.sessionId,
          seqInSessionStart: chunk.first.seqInSession,
          seqInSessionEnd: chunk.last.seqInSession,
        );
      } while (drainAll && _canonicalEventBuffer.isNotEmpty);
    } finally {
      _isFlushingCanonicalBuffer = false;
      _syncBacklogState();
    }
  }

  Future<void> _hydratePendingPublishesFromSpool() async {
    final pending = await _localSpoolService.readPendingBatches(
      limit: maxPendingPublishes,
    );

    _pendingPublishes
      ..clear()
      ..addAll(
        pending.map(
          (record) => _PendingPublish(
            spoolBatchId: record.id,
            topic: record.topic,
            payloadJson: record.payloadJson,
            enqueuedAtUtc: record.enqueuedAtUtc,
            sessionId: record.sessionId,
            seqInSessionStart: record.seqInSessionStart,
            seqInSessionEnd: record.seqInSessionEnd,
          ),
        ),
      );
    _syncSpoolWarningState();
    _syncBacklogState();
  }

  void _syncSpoolWarningState() {
    _localSpoolService.spoolHealth.updatePendingCapacity(
      pendingBatchCount: _pendingPublishes.length,
      pendingBatchCapacity: maxPendingPublishes,
    );
  }

  Future<void> resetSpool() async {
    _pendingPublishes.clear();
    _canonicalEventBuffer.clear();
    await _localSpoolService.clearSpoolBatches();
    await _localSpoolService.clearDecodedEvents();
    _syncSpoolWarningState();
    _syncBacklogState();
  }

  @visibleForTesting
  Future<void> hydratePendingFromSpoolForTest() {
    return _hydratePendingPublishesFromSpool();
  }

  @visibleForTesting
  Future<void> flushPendingPublishesForTest() {
    return _flushPendingPublishes();
  }

  @visibleForTesting
  Future<void> flushCanonicalBufferForTest({bool drainAll = true}) {
    return _flushCanonicalEventBuffer(drainAll: drainAll);
  }

  int get sequenceForCheckpoint {
    return _seqInSession;
  }

  void restoreSessionSequenceFromCheckpoint({
    required String sessionId,
    required int lastSeqInSession,
  }) {
    if (sessionId.isEmpty) {
      return;
    }

    _lastSessionId = sessionId;
    _seqInSession = lastSeqInSession < 0 ? 0 : lastSeqInSession;
  }

  void publishRecoveryDiagnostic({
    required String recoveredSessionId,
    required int recoveredSeqInSession,
  }) {
    restoreSessionSequenceFromCheckpoint(
      sessionId: recoveredSessionId,
      lastSeqInSession: recoveredSeqInSession,
    );
    _publishMetric(
      'Recovery_Resumed',
      1.0,
      requireLogging: false,
      source: 'recovery',
      unit: 'bool',
    );
    unawaited(_flushCanonicalEventBuffer(drainAll: true));
  }

  @visibleForTesting
  int get pendingPublishCountForTest {
    return _pendingPublishes.length;
  }

  @visibleForTesting
  int get canonicalBufferCountForTest {
    return _canonicalEventBuffer.length;
  }

  // The high-speed publisher
  void publish(
    String metricName,
    double value, {
    String source = 'can',
    String? unit,
    int? canId,
  }) {
    _publishMetric(
      metricName,
      value,
      source: source,
      unit: unit,
      canId: canId,
      requireLogging: true,
    );
  }

  @visibleForTesting
  void publishForTest(
    String metricName,
    double value, {
    String source = 'can',
    String? unit,
    int? canId,
  }) {
    _publishMetric(
      metricName,
      value,
      source: source,
      unit: unit,
      canId: canId,
      requireLogging: false,
    );
  }

  void _publishMetric(
    String metricName,
    double value, {
    required bool requireLogging,
    String source = 'can',
    String? unit,
    int? canId,
  }) {
    if (requireLogging && !state.isLogging) {
      return;
    }

    // Sparse Payload Optimization: Only buffer if the value has changed
    if (_lastPublishedValues[metricName] == value) {
      return;
    }
    _lastPublishedValues[metricName] = value;

    final event = _buildDecodedMetricEvent(
      metricName: metricName,
      value: value,
      source: source,
      unit: unit,
      canId: canId,
    );

    unawaited(
      _localSpoolService.enqueueDecodedEvent(
        sessionId: event.sessionId,
        seqInSession: event.seqInSession,
        eventJson: jsonEncode(event.toJson()),
        enqueuedAtUtc: event.tsWallUtc,
      ),
    );

    _canonicalEventBuffer.addLast(event);
    _syncBacklogState();

    if (_canonicalEventBuffer.length >= maxBatchEvents) {
      unawaited(_flushCanonicalEventBuffer(drainAll: true));
    }
  }
}
