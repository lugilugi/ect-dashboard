import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:uuid/uuid.dart';
import '../providers/dashboard_state.dart';

class MqttService {
  final DashboardState state;
  late MqttServerClient _client;
  
  // Generates a unique ID every time the app opens or the user hits "Start Session"
  final String currentSessionId = const Uuid().v4(); 

  MqttService(this.state) {
    // Point this to your trackside laptop's MagicDNS name
    _client = MqttServerClient('pitwall-laptop', 'eco_archers_car');
    _client.port = 1883;
    _client.logging(on: false);
    _client.keepAlivePeriod = 20;
    
    // Auto-reconnect if Tailscale switches towers
    _client.autoReconnect = true; 
    _setupCallbacks();
  }

  Future<void> start() async {
    try {
      print('Connecting to MQTT via Tailscale...');
      await _client.connect();
      if (_client.connectionStatus!.state == MqttConnectionState.connected) {
        print('MQTT Connected!');
        state.setServerConnectionState(true);
      }
    } catch (e) {
      print('MQTT Connection Failed: $e');
      _client.disconnect();
      state.setServerConnectionState(false);
    }
  }

  void stop() {
    _client.disconnect();
    state.setServerConnectionState(false);
  }

  void _setupCallbacks() {
    _client.onConnected = () {
      state.setMqttStatus(MqttStatus.connected); // <--- Update state
    };

    _client.onDisconnected = () {
      state.setMqttStatus(MqttStatus.disconnected); // <--- Update state
    };
  }

  // The high-speed publisher
  void publish(String metricName, double value) {
    if (_client.connectionStatus?.state != MqttConnectionState.connected || !state.isLogging) {
      return;
    }

    final payload = {
      "session_id": state.sessionId,   // Pulled fresh from state
      "session_name": state.sessionName, // Human-readable name
      "can_id": metricName,
      "value": value
    };

    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode(payload));

    _client.publishMessage(
      'telemetry/eco_archers/raw', 
      MqttQos.atLeastOnce, // ensures that data is sent
      builder.payload!,
    );
  }
}