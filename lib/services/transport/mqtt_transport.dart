import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

abstract class MqttTransport {
  Future<void> connect();
  void disconnect();
  bool get isConnected;

  Future<bool> publish({required String topic, required String payloadJson});

  set onConnected(void Function()? callback);
  set onDisconnected(void Function()? callback);
}

/// Exposes [MqttClient.publishingManager] (protected) so the transport can
/// wait for QoS1 publish acknowledgements before handing a payload off.
class _AckAwareMqttServerClient extends MqttServerClient {
  _AckAwareMqttServerClient(super.host, super.clientId);

  PublishingManager? get publishingManagerForAcks => publishingManager;
}

class MqttServerClientTransport implements MqttTransport {
  final _AckAwareMqttServerClient _client;
  final Duration ackTimeout;
  final Map<int, Completer<bool>> _pendingAcks = <int, Completer<bool>>{};
  StreamSubscription<MqttPublishMessage>? _ackSubscription;
  void Function()? _onConnected;
  void Function()? _onDisconnected;

  MqttServerClientTransport({
    required String host,
    required String clientId,
    int port = 1883,
    int keepAliveSeconds = 20,
    bool autoReconnect = false,
    this.ackTimeout = const Duration(seconds: 5),
  }) : _client = _AckAwareMqttServerClient(host, clientId) {
    _client.port = port;
    _client.logging(on: false);
    _client.keepAlivePeriod = keepAliveSeconds;
    _client.autoReconnect = autoReconnect;
    _client.onConnected = () {
      _onConnected?.call();
    };
    _client.onDisconnected = () {
      _ackSubscription?.cancel();
      _ackSubscription = null;
      _failPendingAcks();
      _onDisconnected?.call();
    };
  }

  void _failPendingAcks() {
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _pendingAcks.clear();
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
    _ackSubscription?.cancel();
    _ackSubscription = null;
    _failPendingAcks();
    _client.disconnect();
  }

  @override
  bool get isConnected {
    return _client.connectionStatus?.state == MqttConnectionState.connected;
  }

  @override
  Future<bool> publish({
    required String topic,
    required String payloadJson,
  }) async {
    if (!isConnected) {
      return false;
    }
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(payloadJson);
      final id = _client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      if (id <= 0) {
        return false;
      }

      final completer = Completer<bool>();
      _pendingAcks[id] = completer;
      _ackSubscription ??= _client.publishingManagerForAcks?.published.stream
          .listen((msg) {
            final ackId = msg.variableHeader?.messageIdentifier;
            if (ackId == null) {
              return;
            }
            final pending = _pendingAcks.remove(ackId);
            if (pending != null && !pending.isCompleted) {
              pending.complete(true);
            }
          });
      final timer = Timer(ackTimeout, () {
        _pendingAcks.remove(id)?.complete(false);
      });
      return await completer.future.whenComplete(timer.cancel);
    } catch (_) {
      return false;
    }
  }
}
