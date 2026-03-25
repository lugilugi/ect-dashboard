import 'package:flutter/material.dart';
import 'dart:collection';
import 'dart:async';
import '../models/can_messages.dart';

class DashboardState extends ChangeNotifier {
  // Pedal states
  double throttlePercent = 0.0;
  bool isBrakePressed = false;

  // Aux states
  bool leftTurn = false;
  bool rightTurn = false;
  bool brakeLight = false;
  bool headlights = false;
  bool hazards = false;
  bool horn = false;
  bool wipers = false;

  // Power & Environment
  double mainVoltage = 0.0;
  double current780 = 0.0;
  double current740 = 0.0;
  double mcTempC = 45.0; 
  double battTempC = 35.0;

  // Energy
  double energyJ780 = 0.0;
  double energyJ740 = 0.0;

  // Connections
  bool isConnected = false;
  bool isServerConnected = false;

  // EV Metrics
  double speedKmh = 0.0;
  double distanceKm = 0.0;
  int lapNumber = 1;

  final Queue<double> _speedHistory = Queue<double>();
  final Queue<double> _powerKwHistory = Queue<double>();
  
  double instKmPerKwh = 0.0;
  double avgKmPerKwh = 0.0;

  int errorCount = 0;
  String lastErrorCode = "OK";
  String strategy = "PACE";

  // Debug & Engineer screen
  Map<int, String> lastCanPayloads = {};
  List<double> bmsCells = List.filled(24, 3.80);
  double bus12V = 12.4;
  List<String> mcFaults = ["NONE"];
  
  // GPS
  int gpsSatellites = 0;
  bool gpsLocked = false;

  // Configuration
  String apiUrl = "https://your-backend-api.local/api/telemetry";
  List<double> throttleMap = [0.0, 25.0, 50.0, 75.0, 100.0];

  // Session timer
  int sessionTimeSeconds = 0;
  Timer? _sessionTimer;

  DashboardState() {
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      sessionTimeSeconds++;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    super.dispose();
  }

  String get sessionTimeString {
    int h = sessionTimeSeconds ~/ 3600;
    int m = (sessionTimeSeconds % 3600) ~/ 60;
    int s = sessionTimeSeconds % 60;
    if (h > 0) {
      return '${h.toString()}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get systemTimeString {
    DateTime now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
  }

  void setConnectionState(bool state) {
    isConnected = state;
    notifyListeners();
  }

  void setServerConnectionState(bool state) {
    if (isServerConnected != state) {
      isServerConnected = state;
      notifyListeners();
    }
  }

  void updateApiUrl(String url) {
    apiUrl = url;
    notifyListeners();
  }

  void updateThrottleMap(int index, double value) {
    throttleMap[index] = value;
    notifyListeners();
  }

  void updateThermals(double mc, double batt) {
    mcTempC = mc;
    battTempC = batt;
    notifyListeners();
  }

  void updateErrorCode(String code) {
    lastErrorCode = code;
    notifyListeners();
  }

  void updateRawCan(int id, String payloadHex) {
    lastCanPayloads[id] = payloadHex;
  }

  void updateEngineerMock(List<double> cells, double bus, int sats, bool lock) {
    bmsCells = cells;
    bus12V = bus;
    gpsSatellites = sats;
    gpsLocked = lock;
    notifyListeners();
  }

  void updatePedal(PedalPayload payload) {
    throttlePercent = payload.throttlePercent;
    isBrakePressed = payload.isBrakePressed;
    notifyListeners();
  }

  void updateAux(AuxControlPayload payload) {
    leftTurn = payload.leftTurn;
    rightTurn = payload.rightTurn;
    brakeLight = payload.brakeLight;
    headlights = payload.headlights;
    hazards = payload.hazards;
    horn = payload.horn;
    wipers = payload.wipers;
    notifyListeners();
  }

  void updatePower(PowerPayload payload, int id) {
    mainVoltage = payload.voltage;
    if (id == CanMsgID.pwrMonitor780) {
      current780 = payload.current780;
    } else if (id == CanMsgID.pwrMonitor740) {
      current740 = payload.current740;
    }
    _updateEfficiency();
    notifyListeners();
  }

  void updateEnergy(EnergyPayload payload) {
    energyJ780 = payload.joules780;
    energyJ740 = payload.joules740;
    notifyListeners();
  }

  void updateErrorCount(int count) {
    errorCount = count;
    notifyListeners();
  }

  void updateStrategy(String str) {
    strategy = str;
    notifyListeners();
  }

  void updateMotion(double speed, double distance, int lap) {
    speedKmh = speed;
    distanceKm = distance;
    lapNumber = lap;
    _updateEfficiency();
    notifyListeners();
  }

  void _updateEfficiency() {
    double powerKw = (mainVoltage * current780) / 1000.0; 
    
    _speedHistory.addLast(speedKmh);
    _powerKwHistory.addLast(powerKw);
    if (_speedHistory.length > 10) {
      _speedHistory.removeFirst();
      _powerKwHistory.removeFirst();
    }

    double avgWindowSpeed = _speedHistory.reduce((a, b) => a + b) / _speedHistory.length;
    double avgWindowPower = _powerKwHistory.reduce((a, b) => a + b) / _powerKwHistory.length;

    if (avgWindowPower > 0.5 && avgWindowSpeed > 1.0) {
      instKmPerKwh = avgWindowSpeed / avgWindowPower;
    } else if (powerKw < 0.0 && avgWindowSpeed > 1) {
      instKmPerKwh = 99.9; // Regen max-out
    } else {
      instKmPerKwh = 0.0;
    }

    double totalEnergyKwh = energyJ780 / 3600000.0; 
    if (totalEnergyKwh > 0.001 && distanceKm > 0.001) {
      avgKmPerKwh = distanceKm / totalEnergyKwh;
    }
  }
}
