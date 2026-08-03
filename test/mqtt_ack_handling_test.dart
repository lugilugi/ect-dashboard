import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

class _AckControlledTransport implements MqttTransport {
  bool _connected = false;
  bool autoAck = false;
  void Function()? _onConnected;
  void Function()? _onDisconnected;
  final List<Completer<bool>> pending = <Completer<bool>>[];
  final List<String> publishedPayloads = <String>[];

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
    _connected = true;
    _onConnected?.call();
  }

  @override
  void disconnect() {
    _connected = false;
    _onDisconnected?.call();
  }

  @override
  bool get isConnected => _connected;

  @override
  Future<bool> publish({required String topic, required String payloadJson}) {
    publishedPayloads.add(payloadJson);
    if (autoAck) {
      return Future<bool>.value(true);
    }
    final completer = Completer<bool>();
    pending.add(completer);
    return completer.future;
  }

  void simulateDisconnect() {
    _connected = false;
    _onDisconnected?.call();
  }

  void simulateReconnect() {
    _connected = true;
    _onConnected?.call();
  }

  void ackLast(bool success) {
    final completer = pending.removeLast();
    if (!completer.isCompleted) {
      completer.complete(success);
    }
  }
}

Future<void> _drain([int ticks = 12]) async {
  for (int i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('MqttService ack-confirmed publishing', () {
    test('keeps the batch pending when the broker does not ack', () async {
      final state = DashboardState();
      final spool = LocalSpoolService(forceInMemory: true);
      final transport = _AckControlledTransport();
      final service = MqttService(
        state,
        localSpoolService: spool,
        transport: transport,
      );
      await service.start();
      await _drain();
      expect(transport.isConnected, isTrue);

      service.publishForTest('Speed_Kmh', 31.5);
      unawaited(service.flushCanonicalBufferForTest(drainAll: true));
      await _drain();
      expect(transport.pending, hasLength(1));
      expect(await spool.pendingCount(), 0);

      transport.ackLast(false);
      await _drain();
      expect(await spool.pendingCount(), 1);

      await service.stop();
      state.dispose();
      await spool.close();
    });

    test('marks the spool batch published only after the ack', () async {
      final state = DashboardState();
      final spool = LocalSpoolService(forceInMemory: true);
      final transport = _AckControlledTransport();
      final service = MqttService(
        state,
        localSpoolService: spool,
        transport: transport,
      );
      await service.start();
      await _drain();

      // Go offline so the payload lands in the durable spool first.
      transport.simulateDisconnect();
      service.publishForTest('Speed_Kmh', 31.5);
      await service.flushCanonicalBufferForTest(drainAll: true);
      await _drain();
      expect(await spool.pendingCount(), 1);

      transport.simulateReconnect();
      await _drain();
      expect(transport.pending, hasLength(1));
      expect(await spool.pendingCount(), 1);

      transport.ackLast(true);
      await _drain();
      expect(await spool.pendingCount(), 0);

      await service.stop();
      state.dispose();
      await spool.close();
    });

    test('heartbeat republishes unchanged values while logging', () async {
      final state = DashboardState();
      final spool = LocalSpoolService(forceInMemory: true);
      final transport = _AckControlledTransport();
      final service = MqttService(
        state,
        localSpoolService: spool,
        transport: transport,
      );
      await service.start();
      await _drain();

      service.publishForTest('Speed_Kmh', 31.5);
      unawaited(service.flushCanonicalBufferForTest(drainAll: true));
      await _drain();
      transport.ackLast(true);
      await _drain();

      // Auto-ack session metadata and heartbeat publishes from here on.
      transport.autoAck = true;

      // Wait out the standstill hold so the session actually reaches LOGGING.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      state.startSession('Heartbeat Run');
      expect(state.isLogging, isTrue);
      await _drain();

      service.publishHeartbeat();
      await service.flushCanonicalBufferForTest(drainAll: true);
      await _drain();

      final heartbeatPayloads = transport.publishedPayloads
          .map(
            (payloadJson) =>
                jsonDecode(payloadJson) as Map<String, dynamic>,
          )
          .where((payload) => payload.containsKey('Speed_Kmh'))
          .toList();
      expect(heartbeatPayloads, hasLength(2));
      expect(heartbeatPayloads.last['Speed_Kmh'], 31.5);

      await service.stop();
      state.dispose();
      await spool.close();
    });

    test('canonical buffer stays bounded while a flush is stalled', () async {
      final state = DashboardState();
      final spool = LocalSpoolService(forceInMemory: true);
      final transport = _AckControlledTransport();
      final service = MqttService(
        state,
        localSpoolService: spool,
        transport: transport,
      );
      await service.start();
      await _drain();

      for (int i = 0; i < 400; i++) {
        service.publishForTest('Speed_Kmh', 30.0 + i);
        await Future<void>.delayed(Duration.zero);
      }
      await _drain();

      expect(service.canonicalBufferCountForTest, lessThanOrEqualTo(256));

      while (transport.pending.isNotEmpty) {
        transport.ackLast(false);
        await _drain();
      }
      transport.autoAck = true;

      await service.stop();
      state.dispose();
      await spool.close();
    });
  });
}
