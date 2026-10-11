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

  /// PUBACK deadline for a message with nothing queued ahead of it.
  final Duration ackTimeout;

  /// Extra deadline per message already awaiting its PUBACK when this one is
  /// queued. Concurrent publishes share one socket, so on a slow uplink a
  /// message's bytes leave only after those ahead of it; the deadline grows
  /// with that queue instead of expiring messages still being delivered.
  final Duration ackTimeoutPerQueuedMessage;
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
    this.ackTimeoutPerQueuedMessage = const Duration(seconds: 1),
  }) : _client = _AckAwareMqttServerClient(host, clientId) {
    _client.port = port;
    _client.logging(on: false);
    _client.keepAlivePeriod = keepAliveSeconds;
    _client.autoReconnect = autoReconnect;
    _client.onConnected = () {
      _onConnected?.call();
    };
    _client.onDisconnected = () {
      _unsubscribeAcks();
      _failPendingAcks();
      _onDisconnected?.call();
    };
  }

  /// PUBACK deadline for a message queued behind [queuedAhead] others.
  static Duration ackDeadline(
    Duration base,
    Duration perQueuedMessage,
    int queuedAhead,
  ) => base + perQueuedMessage * queuedAhead;

  void _failPendingAcks() {
    for (final completer in _pendingAcks.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _pendingAcks.clear();
  }

  void _unsubscribeAcks() {
    _ackSubscription?.cancel();
    _ackSubscription = null;
  }

  /// Every connect() creates a new PublishingManager, so acknowledgements
  /// are always read from the current one.
  void _subscribeAcks() {
    _unsubscribeAcks();
    _ackSubscription = _client.publishingManagerForAcks?.published.stream
        .listen(_handlePublished);
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
  Future<void> connect() async {
    _unsubscribeAcks();
    _failPendingAcks();
    await _client.connect();
    if (isConnected) _subscribeAcks();
  }

  @override
  void disconnect() {
    _unsubscribeAcks();
    _failPendingAcks();
    _client.disconnect();
  }

  @override
  bool get isConnected {
    return _client.connectionStatus?.state == MqttConnectionState.connected;
  }

  /// Safe to call concurrently: each QoS1 publish waits for the PUBACK that
  /// carries its own message id. A PUBACK is a broker handoff only.
  @override
  Future<bool> publish({
    required String topic,
    required String payloadJson,
  }) async {
    if (!isConnected) {
      return false;
    }
    final Completer<bool> completer;
    final int id;
    final int queuedAhead;
    try {
      // Subscribe before sending so an acknowledgement is never missed.
      if (_ackSubscription == null) _subscribeAcks();
      queuedAhead = _pendingAcks.length;
      final builder = MqttClientPayloadBuilder();
      builder.addString(payloadJson);
      id = _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      if (id <= 0) {
        return false;
      }
      completer = Completer<bool>();
      // Message ids wrap at 65535; if an id is reused while an older publish
      // is still registered, that older publish can no longer be matched to
      // its PUBACK, so it fails (and is retried) instead of hanging.
      final previous = _pendingAcks[id];
      if (previous != null && !previous.isCompleted) previous.complete(false);
      _pendingAcks[id] = completer;
    } catch (_) {
      // Client-side send failure (socket closed mid-publish); caller retries.
      return false;
    }
    final timer = Timer(
      ackDeadline(ackTimeout, ackTimeoutPerQueuedMessage, queuedAhead),
      () {
        // Only time out our own registration, never a later reuse of the id.
        if (identical(_pendingAcks[id], completer)) _pendingAcks.remove(id);
        if (!completer.isCompleted) completer.complete(false);
      },
    );
    return completer.future.whenComplete(timer.cancel);
  }

  void _handlePublished(MqttPublishMessage msg) {
    final ackId = msg.variableHeader?.messageIdentifier;
    if (ackId == null) {
      return;
    }
    final pending = _pendingAcks.remove(ackId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(true);
    }
  }
}
