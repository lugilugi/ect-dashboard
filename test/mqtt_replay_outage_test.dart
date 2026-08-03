import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

class _PublishedMessage {
  final String topic;
  final String payloadJson;

  const _PublishedMessage({required this.topic, required this.payloadJson});
}

class _FakeMqttTransport implements MqttTransport {
  bool _connected = false;
  void Function()? _onConnected;
  void Function()? _onDisconnected;

  final List<_PublishedMessage> publishedMessages = <_PublishedMessage>[];

  @override
  set onConnected(void Function()? callback) {
    _onConnected = callback;
  }

  @override
  set onDisconnected(void Function()? callback) {
    _onDisconnected = callback;
  }

  @override
  Future<void> connect() async {
    simulateReconnect();
  }

  @override
  void disconnect() {
    simulateDisconnect();
  }

  @override
  bool get isConnected {
    return _connected;
  }

  @override
  Future<bool> publish({
    required String topic,
    required String payloadJson,
  }) async {
    if (!_connected) {
      return false;
    }

    publishedMessages.add(
      _PublishedMessage(topic: topic, payloadJson: payloadJson),
    );
    return true;
  }

  void simulateReconnect() {
    _connected = true;
    _onConnected?.call();
  }

  void simulateDisconnect() {
    _connected = false;
    _onDisconnected?.call();
  }
}

class _FailingSpool extends LocalSpoolService {
  _FailingSpool() : super(forceInMemory: true);

  bool failNextEnqueue = false;

  @override
  Future<int> enqueueBatch({
    required String topic,
    required String payloadJson,
    DateTime? enqueuedAtUtc,
    String? sessionId,
    int? seqInSessionStart,
    int? seqInSessionEnd,
  }) async {
    if (failNextEnqueue) {
      throw StateError('spool unavailable');
    }
    return super.enqueueBatch(
      topic: topic,
      payloadJson: payloadJson,
      enqueuedAtUtc: enqueuedAtUtc,
      sessionId: sessionId,
      seqInSessionStart: seqInSessionStart,
      seqInSessionEnd: seqInSessionEnd,
    );
  }
}

class _FlakyMqttTransport extends _FakeMqttTransport {
  int connectAttempts = 0;

  @override
  Future<void> connect() async {
    connectAttempts += 1;
    if (connectAttempts == 1) {
      throw Exception('broker unreachable');
    }
    await super.connect();
  }
}

Future<void> _drainMicrotasks([int ticks = 8]) async {
  for (int i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<int> _extractSequenceOrder(List<_PublishedMessage> publishedMessages) {
  return publishedMessages
      .map((message) {
        final payload = jsonDecode(message.payloadJson) as Map<String, dynamic>;
        return (payload['seq_in_session_start'] as num).toInt();
      })
      .toList(growable: false);
}

bool _assertSparseContract(_PublishedMessage message, {int? lapNumber}) {
  final payload = jsonDecode(message.payloadJson) as Map<String, dynamic>;
  final hasRequired =
      payload.containsKey('session_uid') &&
      payload.containsKey('lap_number') &&
      payload.containsKey('ts_wall_utc') &&
      payload.containsKey('ts_session_ms') &&
      payload.containsKey('seq_in_session_start') &&
      payload.containsKey('seq_in_session_end');
  if (!hasRequired) {
    return false;
  }
  if (lapNumber != null && (payload['lap_number'] as num).toInt() != lapNumber) {
    return false;
  }
  final hasEventsArray = payload.containsKey('events') && payload['events'] is List;
  return !hasEventsArray;
}

void main() {
  group('MqttService outage replay', () {
    test(
      'buffers during outage and flushes pending batches in order',
      () async {
        final state = DashboardState();
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 64,
        );
        final transport = _FakeMqttTransport();
        final service = MqttService(
          state,
          localSpoolService: spool,
          transport: transport,
        );

        for (final value in <double>[10.0, 20.0, 30.0]) {
          service.publishForTest(
            'Speed_Kmh',
            value,
            source: 'external_gps',
            unit: 'km/h',
            canId: 0x500,
          );
          await service.flushCanonicalBufferForTest(drainAll: true);
        }

        expect(service.pendingPublishCountForTest, 3);
        expect(await spool.pendingCount(), 3);

        transport.simulateReconnect();
        await _drainMicrotasks();

        expect(service.pendingPublishCountForTest, 0);
        expect(await spool.pendingCount(), 0);
        expect(transport.publishedMessages.length, 3);
        for (final message in transport.publishedMessages) {
          expect(_assertSparseContract(message), isTrue);
        }
        expect(
          _extractSequenceOrder(transport.publishedMessages),
          equals(<int>[1, 2, 3]),
        );

        state.dispose();
        await spool.close();
      },
    );

    test(
      'replays pending spool batches across service restart with no loss',
      () async {
        final state = DashboardState();
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 64,
        );

        final firstTransport = _FakeMqttTransport();
        final firstService = MqttService(
          state,
          localSpoolService: spool,
          transport: firstTransport,
        );

        for (final value in <double>[11.0, 22.0, 33.0, 44.0]) {
          firstService.publishForTest(
            'Voltage_780',
            value,
            source: 'can',
            unit: 'V',
            canId: 0x310,
          );
          await firstService.flushCanonicalBufferForTest(drainAll: true);
        }
        await _drainMicrotasks();

        expect(await spool.pendingCount(), 4);
        expect(await spool.pendingDecodedEventCount(), 4);

        final replayTransport = _FakeMqttTransport();
        final replayService = MqttService(
          state,
          localSpoolService: spool,
          transport: replayTransport,
        );

        await replayService.hydratePendingFromSpoolForTest();
        expect(replayService.pendingPublishCountForTest, 4);

        replayTransport.simulateReconnect();
        await _drainMicrotasks();

        expect(replayService.pendingPublishCountForTest, 0);
        expect(await spool.pendingCount(), 0);
        expect(await spool.pendingDecodedEventCount(), 0);
        expect(replayTransport.publishedMessages.length, 4);
        for (final message in replayTransport.publishedMessages) {
          expect(_assertSparseContract(message), isTrue);
        }
        expect(
          _extractSequenceOrder(replayTransport.publishedMessages),
          equals(<int>[1, 2, 3, 4]),
        );

        state.dispose();
        await spool.close();
      },
    );
  });

  group('MqttService session metadata handoff', () {
    List<_PublishedMessage> sessionsMessages(_FakeMqttTransport transport) {
      return transport.publishedMessages
          .where((m) => m.topic == 'telemetry/eco_archers/sessions')
          .toList(growable: false);
    }

    test(
      'metadata published while offline is queued and delivered on reconnect',
      () async {
        final state = DashboardState();
        final spool = LocalSpoolService(forceInMemory: true);
        final transport = _FakeMqttTransport();
        final service = MqttService(
          state,
          localSpoolService: spool,
          transport: transport,
        );

        state.startSession('Offline Metadata');
        service.publishSessionMetadata();
        await _drainMicrotasks();

        // Offline: nothing sent yet, but the batch is durably queued.
        expect(transport.publishedMessages, isEmpty);
        expect(await spool.pendingCount(), 1);

        transport.simulateReconnect();
        await _drainMicrotasks();

        final sessionsMsgs = sessionsMessages(transport);
        expect(sessionsMsgs, hasLength(1));
        final payload =
            jsonDecode(sessionsMsgs.first.payloadJson)
                as Map<String, dynamic>;
        expect(payload['uid'], state.sessionId);
        expect(payload['session_name'], 'Offline Metadata');

        state.dispose();
        await spool.close();
      },
    );

    test(
      'metadata is re-published on reconnect when the first handoff failed',
      () async {
        final state = DashboardState();
        final spool = _FailingSpool();
        final transport = _FakeMqttTransport();
        final service = MqttService(
          state,
          localSpoolService: spool,
          transport: transport,
        );

        state.startSession('Retry Metadata');
        state.lapsCompleted = 2;

        // First attempt: offline AND the spool is unavailable -> not handed
        // off. The dedup cache must stay stale.
        spool.failNextEnqueue = true;
        service.publishSessionMetadata();
        await _drainMicrotasks();
        expect(transport.publishedMessages, isEmpty);

        // Reconnect: the stale cache triggers a direct re-publish.
        transport.simulateReconnect();
        await _drainMicrotasks();

        final sessionsMsgs = sessionsMessages(transport);
        expect(sessionsMsgs, hasLength(1));
        final payload =
            jsonDecode(sessionsMsgs.first.payloadJson)
                as Map<String, dynamic>;
        expect(payload['uid'], state.sessionId);
        expect(payload['session_name'], 'Retry Metadata');

        // Subsequent identical metadata is deduped.
        service.publishSessionMetadata();
        await _drainMicrotasks();
        expect(sessionsMessages(transport), hasLength(1));

        // A real change publishes again.
        state.lapsCompleted = 3;
        service.publishSessionMetadata();
        await _drainMicrotasks();
        final afterChange = sessionsMessages(transport);
        expect(afterChange, hasLength(2));
        final updated =
            jsonDecode(afterChange.last.payloadJson) as Map<String, dynamic>;
        expect(
          (updated['vehicle_setup'] as String),
          contains('"laps_completed":3'),
        );

        state.dispose();
        await spool.close();
      },
    );
  });

  group('MqttService connect retry', () {
    test(
      'keeps retrying a failed initial connect until the broker is reachable',
      () async {
        final state = DashboardState();
        final spool = LocalSpoolService(forceInMemory: true);
        final transport = _FlakyMqttTransport();
        final service = MqttService(
          state,
          localSpoolService: spool,
          transport: transport,
          mqttRetryInterval: const Duration(milliseconds: 50),
        );

        await service.start();
        await _drainMicrotasks();

        // Give the 50ms retry timer time to fire after the first failed
        // attempt and connect on a later one.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await _drainMicrotasks();

        expect(transport.connectAttempts, greaterThan(1));
        expect(transport.isConnected, isTrue);
        expect(state.isServerConnected, isTrue);

        // The retry loop stays quiet once connected.
        final attemptsAfterConnect = transport.connectAttempts;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(transport.connectAttempts, attemptsAfterConnect);

        await service.stop();
        state.dispose();
        await spool.close();
      },
    );

    test(
      'reconnects after an established connection drops',
      () async {
        final state = DashboardState();
        final spool = LocalSpoolService(forceInMemory: true);
        final transport = _FakeMqttTransport();
        final service = MqttService(
          state,
          localSpoolService: spool,
          transport: transport,
          mqttRetryInterval: const Duration(milliseconds: 50),
        );

        await service.start();
        await _drainMicrotasks();
        expect(state.isServerConnected, isTrue);

        // Simulate the broker going away, then coming back.
        transport.simulateDisconnect();
        expect(state.isServerConnected, isFalse);
        expect(transport.isConnected, isFalse);

        transport.simulateReconnect();
        await _drainMicrotasks();
        expect(transport.isConnected, isTrue);
        expect(state.isServerConnected, isTrue);

        await service.stop();
        state.dispose();
        await spool.close();
      },
    );
  });
}
