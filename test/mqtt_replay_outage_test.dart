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
  bool publish({required String topic, required String payloadJson}) {
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

Future<void> _drainMicrotasks([int ticks = 8]) async {
  for (int i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<int> _extractSequenceOrder(List<_PublishedMessage> publishedMessages) {
  return publishedMessages
      .map((message) {
        final payload = jsonDecode(message.payloadJson) as Map<String, dynamic>;
        final events = payload['events'] as List<dynamic>;
        final event = events.first as Map<String, dynamic>;
        return (event['seq_in_session'] as num).toInt();
      })
      .toList(growable: false);
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
        expect(
          _extractSequenceOrder(replayTransport.publishedMessages),
          equals(<int>[1, 2, 3, 4]),
        );

        state.dispose();
        await spool.close();
      },
    );
  });
}
