import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../providers/dashboard_state.dart';

class ApiService {
  final DashboardState state;
  Timer? _syncTimer;

  ApiService(this.state);

  void start() {
    // Sync telemetry data to the backend every 1 second
    _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sendData();
    });
  }

  void stop() {
    _syncTimer?.cancel();
  }

  Future<void> _sendData() async {
    // Local simulation logic relies on state entirely.
    // Allow sending even if USB is mocked for debugging, but require a live API endpoint.
    
    final payload = {
      "timestamp": DateTime.now().toIso8601String(),
      "throttlePercent": state.throttlePercent,
      "isBrakePressed": state.isBrakePressed,
      "indicators": {
        "leftTurn": state.leftTurn,
        "rightTurn": state.rightTurn,
        "headlights": state.headlights,
        "hazards": state.hazards,
        "horn": state.horn,
        "wipers": state.wipers,
      },
      "power": {
        "mainVoltage": state.mainVoltage,
        "current780": state.current780,
        "current740": state.current740,
        "mcTempC": state.mcTempC,     
      },
      "energy": {
        "joules780": state.energyJ780,
        "joules740": state.energyJ740,
      }
    };

    try {
      final response = await http.post(
        Uri.parse(state.apiUrl),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        state.setServerConnectionState(true);
      } else {
        state.setServerConnectionState(false);
      }
    } catch (e) {
      state.setServerConnectionState(false);
    }
  }
}
