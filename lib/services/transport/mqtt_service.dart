import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';
import 'mqtt_transport.dart';
export 'mqtt_transport.dart';

/// One message in a delivery round: either an event envelope or one session
/// metadata record.
class _Outgoing {
  final bool metrics;
  final List<PendingJournalRecord> rows = [];
  int bytes;
  _Outgoing.metrics() : metrics = true, bytes = MqttService.envelopeOverhead;
  _Outgoing.session(PendingJournalRecord row)
    : metrics = false,
      bytes = row.payloadBytes {
    rows.add(row);
  }

  String get topic =>
      metrics ? MqttService.eventsTopic : MqttService.sessionsTopic;

  /// Stored payload_json values are joined verbatim; nothing is re-encoded.
  String get payloadJson {
    if (!metrics) return rows.single.record.payloadJson;
    final buffer = StringBuffer(MqttService.envelopePrefix);
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(rows[i].record.payloadJson);
    }
    buffer.write(MqttService.envelopeSuffix);
    return buffer.toString();
  }
}

/// One owner for connection retry and delivery of committed records.
/// A broker PUBACK is a handoff, not proof of database insertion.
///
/// The sender wakes on each journal commit, publishes up to [maxInFlight]
/// messages concurrently per round, and keeps pumping rounds while a backlog
/// exists and the link is connected. Rounds are strict: the next read starts
/// after the previous round's acknowledgements are committed, so no record
/// is ever in two in-flight messages. Delivery order is unconstrained and
/// at-least-once.
class MqttService {
  final DashboardState state;
  final TelemetryJournal journal;
  final bool _injectedTransport;
  final int maxInFlight;
  final int readLimit;
  final Duration minReconnectDelay;
  final Duration maxReconnectDelay;
  final Duration fallbackInterval;
  final DateTime Function() _now;
  MqttTransport? _transport;
  Timer? _timer;
  StreamSubscription<int>? _commitSubscription;
  Future<void>? _connecting;
  Future<void>? _sending;
  bool _rerun = false;
  bool _started = false;
  bool _halted = false;
  String _endpoint = '';
  Duration _reconnectDelay;
  DateTime? _nextConnectAt;
  DateTime? _publishRetryAt;

  static const packetBytes = 32 * 1024;
  static const eventsTopic = 'telemetry/eco_archers/events';
  static const sessionsTopic = 'telemetry/eco_archers/sessions';
  static const envelopePrefix = '{"schema_version":2,"events":[';
  static const envelopeSuffix = ']}';
  static const envelopeOverhead = envelopePrefix.length + envelopeSuffix.length;

  MqttService(
    this.state, {
    required this.journal,
    MqttTransport? transport,
    this.maxInFlight = 8,
    this.readLimit = 256,
    this.minReconnectDelay = const Duration(seconds: 1),
    this.maxReconnectDelay = const Duration(seconds: 15),
    this.fallbackInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _transport = transport,
       _injectedTransport = transport != null,
       _reconnectDelay = minReconnectDelay,
       _now = now ?? (() => DateTime.now().toUtc());

  /// Current reconnect backoff (doubles per failed connect, reset on success).
  Duration get reconnectDelay => _reconnectDelay;

  Future<void> start() async {
    if (_started) return;
    await journal.initialize();
    _started = true;
    _halted = false;
    state.addListener(_checkEndpoint);
    _checkEndpoint();
    _commitSubscription = journal.commits.listen((_) => _wake());
    // Fallback for reconnect and retry after failure; commits wake directly.
    _timer = Timer.periodic(fallbackInterval, (_) {
      unawaited(_tick());
    });
    unawaited(_tick());
  }

  void _checkEndpoint() {
    final endpoint = '${state.mqttHost}:${state.mqttPort}';
    if (_injectedTransport || _endpoint == endpoint) return;
    _endpoint = endpoint;
    _transport?.disconnect();
    final transport = MqttServerClientTransport(
      host: state.mqttHost,
      port: state.mqttPort,
      clientId: 'ect-edge-${const Uuid().v4()}',
    );
    _transport = transport;
    _reconnectDelay = minReconnectDelay;
    _nextConnectAt = null;
    transport.onConnected = () {
      if (_started && identical(_transport, transport)) {
        state.setServerConnectionState(true);
      }
    };
    transport.onDisconnected = () {
      if (_started && identical(_transport, transport)) {
        state.setServerConnectionState(false);
      }
    };
    unawaited(_tick());
  }

  /// Commit signal: pump immediately unless a failed round is cooling down
  /// (the fallback tick retries it).
  void _wake() {
    if (!_started || _transport?.isConnected != true) return;
    final retryAt = _publishRetryAt;
    if (retryAt != null && _now().isBefore(retryAt)) return;
    unawaited(_flushSafely());
  }

  Future<void> _tick() async {
    if (!_started) return;
    if (_transport?.isConnected != true) {
      final at = _nextConnectAt;
      if (at != null && _now().isBefore(at)) return;
      await (_connecting ??= _connect().whenComplete(() => _connecting = null));
    }
    if (_started && _transport?.isConnected == true) await _flushSafely();
  }

  Future<void> _flushSafely() async {
    try {
      await flush();
    } catch (error) {
      journal.spoolHealth.updateDeliveryError('Delivery failed: $error');
    }
  }

  Future<void> _connect() async {
    final transport = _transport;
    if (transport == null) return;
    Object? failure;
    try {
      await transport.connect();
    } catch (error) {
      failure = error;
    }
    if (!_started || !identical(_transport, transport)) return;
    final connected = transport.isConnected;
    state.setServerConnectionState(connected);
    if (connected) {
      _reconnectDelay = minReconnectDelay;
      _nextConnectAt = null;
      journal.spoolHealth.updateDeliveryError(null);
    } else {
      _nextConnectAt = _now().add(_reconnectDelay);
      final doubled = _reconnectDelay * 2;
      _reconnectDelay = doubled > maxReconnectDelay
          ? maxReconnectDelay
          : doubled;
      journal.spoolHealth.updateDeliveryError(
        'Broker connect failed${failure == null ? '' : ': $failure'}',
      );
    }
  }

  /// Delivers every record committed before this call, if connected. Calls
  /// made while a pump is running extend it rather than starting another.
  Future<void> flush() {
    _rerun = true;
    return _sending ??= _drive();
  }

  Future<void> _drive() async {
    try {
      while (_rerun && !_halted) {
        _rerun = false;
        await _pump();
      }
    } finally {
      _sending = null;
    }
  }

  Future<void> _pump() async {
    while (!_halted) {
      final transport = _transport;
      if (transport == null || !transport.isConnected) return;
      final pending = await journal.readPending(limit: readLimit);
      if (pending.isEmpty) return;
      final round = await _selectRound(pending);
      if (round.isEmpty) continue;
      final results = await Future.wait([
        for (final message in round) _publish(transport, message),
      ]);
      final acked = <int>[];
      final failed = <int>[];
      for (var i = 0; i < round.length; i++) {
        final ids = round[i].rows.map((r) => r.id);
        (results[i] ? acked : failed).addAll(ids);
      }
      // Acked siblings are recorded even when another message failed.
      await journal.recordDeliveryRound(
        acked: acked,
        failed: failed,
        error: failed.isEmpty ? null : 'PUBACK unavailable',
      );
      if (failed.isNotEmpty) {
        _publishRetryAt = _now().add(minReconnectDelay);
        return;
      }
      _publishRetryAt = null;
    }
  }

  Future<bool> _publish(MqttTransport transport, _Outgoing message) async {
    try {
      return await transport.publish(
        topic: message.topic,
        payloadJson: message.payloadJson,
      );
    } catch (error) {
      journal.spoolHealth.updateDeliveryError('Publish failed: $error');
      return false;
    }
  }

  /// Packs pending rows into at most [maxInFlight] messages of at most
  /// [packetBytes]. Rows that do not fit this round stay pending; a single
  /// record larger than the packet budget is dropped.
  Future<List<_Outgoing>> _selectRound(
    List<PendingJournalRecord> pending,
  ) async {
    final round = <_Outgoing>[];
    _Outgoing? current;
    for (final row in pending) {
      if (row.record.kind == TelemetryRecordKind.session) {
        if (row.payloadBytes > packetBytes) {
          await journal.markDropped(
            row.id,
            'record exceeds MQTT packet budget',
          );
          continue;
        }
        if (round.length >= maxInFlight) break;
        round.add(_Outgoing.session(row));
        continue;
      }
      if (envelopeOverhead + row.payloadBytes > packetBytes) {
        await journal.markDropped(row.id, 'record exceeds MQTT packet budget');
        continue;
      }
      final open = current;
      final separator = open == null || open.rows.isEmpty ? 0 : 1;
      if (open != null &&
          open.bytes + separator + row.payloadBytes <= packetBytes) {
        open.rows.add(row);
        open.bytes += separator + row.payloadBytes;
        continue;
      }
      if (round.length >= maxInFlight) break;
      final next = _Outgoing.metrics()
        ..rows.add(row)
        ..bytes += row.payloadBytes;
      round.add(next);
      current = next;
    }
    return round;
  }

  Future<void> stop() async {
    _started = false;
    _halted = true;
    _timer?.cancel();
    _timer = null;
    await _commitSubscription?.cancel();
    _commitSubscription = null;
    state.removeListener(_checkEndpoint);
    _transport?.disconnect();
    await _connecting;
    // connect() might complete after cancellation.
    _transport?.disconnect();
    await _sending;
    state.setServerConnectionState(false);
  }
}
