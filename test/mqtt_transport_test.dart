import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_transport.dart';

/// Minimal MQTT 3.1/3.1.1 broker: CONNACK, PUBACK (optionally delayed),
/// PINGRESP. Enough to exercise the real mqtt_client transport.
class FakeBroker {
  late final ServerSocket _server;
  final sockets = <Socket>[];
  Duration ackDelay = Duration.zero;
  int connects = 0;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  void _serve(Socket socket) {
    sockets.add(socket);
    var buffer = <int>[];
    socket.listen(
      (data) {
        buffer.addAll(data);
        while (true) {
          final packet = _take(buffer);
          if (packet == null) break;
          buffer = packet.rest;
          _handle(socket, packet.type, packet.body);
        }
      },
      onError: (_) {},
      onDone: () => sockets.remove(socket),
    );
  }

  ({int type, List<int> body, List<int> rest})? _take(List<int> buffer) {
    if (buffer.length < 2) return null;
    var length = 0;
    var multiplier = 1;
    var index = 1;
    while (true) {
      if (index >= buffer.length) return null;
      final byte = buffer[index++];
      length += (byte & 127) * multiplier;
      if (byte & 128 == 0) break;
      multiplier *= 128;
    }
    if (buffer.length < index + length) return null;
    return (
      type: buffer[0],
      body: buffer.sublist(index, index + length),
      rest: buffer.sublist(index + length),
    );
  }

  void _handle(Socket socket, int header, List<int> body) {
    switch (header >> 4) {
      case 1: // CONNECT
        connects++;
        socket.add([0x20, 0x02, 0x00, 0x00]);
      case 3: // PUBLISH
        if ((header >> 1) & 3 == 1) {
          final topicLength = (body[0] << 8) | body[1];
          final hi = body[2 + topicLength];
          final lo = body[3 + topicLength];
          void ack() {
            try {
              socket.add([0x40, 0x02, hi, lo]);
            } catch (_) {}
          }

          if (ackDelay == Duration.zero) {
            ack();
          } else {
            Timer(ackDelay, ack);
          }
        }
      case 12: // PINGREQ
        socket.add([0xD0, 0x00]);
      case 14: // DISCONNECT
        socket.destroy();
    }
  }

  /// Drops every client connection without an MQTT DISCONNECT.
  void dropClients() {
    for (final socket in List.of(sockets)) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    dropClients();
    await _server.close();
  }
}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeBroker broker;
  setUp(() async {
    broker = FakeBroker();
    await broker.start();
  });
  tearDown(() => broker.close());

  MqttServerClientTransport transport({
    Duration ackTimeout = const Duration(seconds: 2),
    Duration perQueued = const Duration(seconds: 1),
  }) => MqttServerClientTransport(
    host: '127.0.0.1',
    port: broker.port,
    clientId: 'ect-transport-test',
    ackTimeout: ackTimeout,
    ackTimeoutPerQueuedMessage: perQueued,
  );

  Future<bool> send(MqttServerClientTransport t, [String body = '{}']) =>
      t.publish(topic: 'telemetry/test', payloadJson: body);

  test('acknowledgements are received again after a reconnect', () async {
    final client = transport();
    var disconnected = 0;
    client.onDisconnected = () => disconnected++;
    await client.connect();
    expect(await send(client), isTrue);

    // Broker drops the link; a new connect creates a new PublishingManager.
    broker.dropClients();
    await waitFor(() => !client.isConnected);
    expect(await send(client), isFalse);
    await client.connect();
    expect(client.isConnected, isTrue);
    expect(await send(client), isTrue);

    // A client-initiated disconnect and reconnect also resubscribes.
    client.disconnect();
    await client.connect();
    expect(await send(client), isTrue);
    expect(broker.connects, 3);
    client.disconnect();
    expect(disconnected, greaterThanOrEqualTo(1));
  });

  test('ack deadline grows with the messages queued ahead', () async {
    // Base 150 ms, +250 ms per queued message; PUBACKs arrive after 300 ms.
    final client = transport(
      ackTimeout: const Duration(milliseconds: 150),
      perQueued: const Duration(milliseconds: 250),
    );
    await client.connect();
    broker.ackDelay = const Duration(milliseconds: 300);
    final results = await Future.wait([
      send(client, '{"n":1}'),
      send(client, '{"n":2}'),
      send(client, '{"n":3}'),
    ]);
    // First (150 ms) expires; the second (400 ms) and third (650 ms) do not.
    expect(results, [false, true, true]);
    client.disconnect();
  });

  test('concurrent publishes each match their own PUBACK', () async {
    final client = transport();
    await client.connect();
    final results = await Future.wait([
      for (var i = 0; i < 8; i++) send(client, '{"n":$i}'),
    ]);
    expect(results, everyElement(isTrue));
    client.disconnect();
  });

  test('ackDeadline is linear in queue depth', () {
    expect(
      MqttServerClientTransport.ackDeadline(
        const Duration(seconds: 5),
        const Duration(seconds: 1),
        0,
      ),
      const Duration(seconds: 5),
    );
  });
}
