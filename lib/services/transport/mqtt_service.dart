import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';
import 'mqtt_transport.dart';
export 'mqtt_transport.dart';

/// One owner for connection retry and FIFO delivery of committed records.
/// A broker PUBACK is a handoff, not proof of database insertion.
class MqttService {
  final DashboardState state;
  final TelemetryJournal journal;
  final bool _injectedTransport;
  MqttTransport? _transport;
  Timer? _timer;
  Future<void>? _connecting;
  Future<void>? _sending;
  bool _started = false;
  String _endpoint = '';
  static const packetBytes = 32 * 1024;
  static const eventsTopic = 'telemetry/eco_archers/events';
  static const sessionsTopic = 'telemetry/eco_archers/sessions';

  MqttService(this.state, {required this.journal, MqttTransport? transport})
    : _transport = transport,
      _injectedTransport = transport != null;

  Future<void> start() async {
    if (_started) return;
    await journal.initialize();
    _started = true;
    state.addListener(_checkEndpoint);
    _checkEndpoint();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
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

  Future<void> _tick() async {
    if (!_started) return;
    try {
      if (_transport?.isConnected != true) {
        await (_connecting ??= _connect().whenComplete(
          () => _connecting = null,
        ));
      }
      if (_started) await flush();
    } catch (error) {
      journal.spoolHealth.updateRecordingErrors(
        storage: journal.spoolHealth.storageError,
        export: journal.spoolHealth.exportError,
      );
    }
  }

  Future<void> _connect() async {
    final transport = _transport;
    if (transport == null) return;
    try {
      await transport.connect();
    } catch (_) {}
    if (_started && identical(_transport, transport)) {
      state.setServerConnectionState(transport.isConnected);
    }
  }

  Future<void> flush() =>
      _sending ??= _pump().whenComplete(() => _sending = null);

  Future<void> _pump() async {
    // Bound each turn so live capture and stop never wait for an entire outage.
    for (var turn = 0; turn < 8; turn++) {
      final transport = _transport;
      if (transport?.isConnected != true) return;
      final pending = await journal.readPending(limit: 32);
      if (pending.isEmpty) return;
      final metrics = pending.first.record.kind == TelemetryRecordKind.metric;
      final selected = <PendingJournalRecord>[];
      String encode() => metrics
          ? jsonEncode({
              'schema_version': 2,
              'events': selected.map((r) => r.record.payload).toList(),
            })
          : selected.single.record.payloadJson;
      for (final row in pending) {
        if ((row.record.kind == TelemetryRecordKind.metric) != metrics) break;
        selected.add(row);
        if (utf8.encode(encode()).length > packetBytes) {
          selected.removeLast();
          if (selected.isEmpty) {
            await journal.markDropped(
              row.id,
              'record exceeds MQTT packet budget',
            );
          }
          break;
        }
        if (!metrics) break;
      }
      if (selected.isEmpty) continue;
      final ids = selected.map((r) => r.id).toList();
      final success = await transport!.publish(
        topic: metrics ? eventsTopic : sessionsTopic,
        payloadJson: encode(),
      );
      await journal.recordAttempt(
        ids,
        error: success ? null : 'PUBACK unavailable',
      );
      if (!success) return;
      await journal.markBrokerAcknowledged(ids);
    }
  }

  Future<void> stop() async {
    _started = false;
    _timer?.cancel();
    state.removeListener(_checkEndpoint);
    _transport?.disconnect();
    await _connecting;
    // connect() might complete after cancellation.
    _transport?.disconnect();
    await _sending;
    state.setServerConnectionState(false);
  }
}
