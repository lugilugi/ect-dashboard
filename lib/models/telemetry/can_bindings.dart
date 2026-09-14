import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

enum CanValueTransform {
  identity,
  throttleCommandToPercent,
  metresToKilometres,
}

class CanTelemetryBinding {
  final int canId;
  final String dbcSignalName;
  final String metricName;
  final String unit;
  final String source;
  final CanValueTransform transform;

  const CanTelemetryBinding({
    required this.canId,
    required this.dbcSignalName,
    required this.metricName,
    required this.unit,
    this.source = 'can',
    this.transform = CanValueTransform.identity,
  });

  double transformValue(double value) {
    switch (transform) {
      case CanValueTransform.identity:
        return value;
      case CanValueTransform.throttleCommandToPercent:
        return value.clamp(0.0, 32767.0).toDouble() / 32767.0 * 100.0;
      case CanValueTransform.metresToKilometres:
        return value / 1000.0;
    }
  }
}

/// The app-owned telemetry contract. DBC names remain protocol names; these
/// bindings preserve the metric names and units used by MQTT, Grafana, and
/// historical data.
const List<CanTelemetryBinding> canTelemetryBindings = <CanTelemetryBinding>[
  CanTelemetryBinding(
    canId: CanIds.pedalStatus,
    dbcSignalName: 'throttle_command',
    metricName: 'Throttle_Percent',
    unit: '%',
    transform: CanValueTransform.throttleCommandToPercent,
  ),
  CanTelemetryBinding(
    canId: CanIds.pedalStatus,
    dbcSignalName: 'brake_active',
    metricName: 'Brake_Active',
    unit: 'bool',
  ),
  CanTelemetryBinding(
    canId: CanIds.pedalStatus,
    dbcSignalName: 'deadman_active',
    metricName: 'Deadman_Active',
    unit: 'bool',
  ),
  CanTelemetryBinding(
    canId: CanIds.packPower,
    dbcSignalName: 'voltage_v',
    metricName: 'Voltage_780',
    unit: 'V',
  ),
  CanTelemetryBinding(
    canId: CanIds.packPower,
    dbcSignalName: 'current_a',
    metricName: 'Current_780',
    unit: 'A',
  ),
  CanTelemetryBinding(
    canId: CanIds.auxPower,
    dbcSignalName: 'voltage_v',
    metricName: 'Voltage_740',
    unit: 'V',
  ),
  CanTelemetryBinding(
    canId: CanIds.auxPower,
    dbcSignalName: 'current_a',
    metricName: 'Current_740',
    unit: 'A',
  ),
  CanTelemetryBinding(
    canId: CanIds.packEnergy,
    dbcSignalName: 'energy_j',
    metricName: 'Joules_780',
    unit: 'J',
  ),
  CanTelemetryBinding(
    canId: CanIds.vehicleMotion,
    dbcSignalName: 'speed_kmh',
    metricName: 'Speed_Kmh',
    unit: 'km/h',
  ),
  CanTelemetryBinding(
    canId: CanIds.vehicleMotion,
    dbcSignalName: 'trip_distance_m',
    metricName: 'Distance_Km',
    unit: 'km',
    transform: CanValueTransform.metresToKilometres,
  ),
  CanTelemetryBinding(
    canId: CanIds.gpsStatus,
    dbcSignalName: 'satellites',
    metricName: 'GPS_Satellites',
    unit: 'count',
    source: 'external_gps',
  ),
  CanTelemetryBinding(
    canId: CanIds.gpsStatus,
    dbcSignalName: 'fix_valid',
    metricName: 'GPS_Locked',
    unit: 'bool',
    source: 'external_gps',
  ),
  CanTelemetryBinding(
    canId: CanIds.gpsPosition,
    dbcSignalName: 'latitude_deg',
    metricName: 'GPS_Latitude_Deg',
    unit: 'deg',
    source: 'external_gps',
  ),
  CanTelemetryBinding(
    canId: CanIds.gpsPosition,
    dbcSignalName: 'longitude_deg',
    metricName: 'GPS_Longitude_Deg',
    unit: 'deg',
    source: 'external_gps',
  ),
  CanTelemetryBinding(
    canId: CanIds.gpsMotion,
    dbcSignalName: 'gps_speed_kmh',
    metricName: 'GPS_Speed_Kmh',
    unit: 'km/h',
    source: 'external_gps',
  ),
  CanTelemetryBinding(
    canId: CanIds.gpsMotion,
    dbcSignalName: 'heading_deg',
    metricName: 'GPS_Heading_Deg',
    unit: 'deg',
    source: 'external_gps',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorState,
    dbcSignalName: 'motor_speed_rpm',
    metricName: 'Motor_Speed_Rpm',
    unit: 'rpm',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorState,
    dbcSignalName: 'sequencer_state',
    metricName: 'Motor_Sequencer_State',
    unit: 'state',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorState,
    dbcSignalName: 'motor_status',
    metricName: 'Motor_Status',
    unit: 'bitfield',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorCurrent,
    dbcSignalName: 'iq_a',
    metricName: 'Motor_Iq_A',
    unit: 'A',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorCurrent,
    dbcSignalName: 'id_a',
    metricName: 'Motor_Id_A',
    unit: 'A',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorCurrent,
    dbcSignalName: 'motor_current_a',
    metricName: 'Motor_Current_A',
    unit: 'A',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorVoltage,
    dbcSignalName: 'dc_bus_voltage_v',
    metricName: 'DC_Bus_Voltage_V',
    unit: 'V',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorVoltage,
    dbcSignalName: 'vq_v',
    metricName: 'Motor_Vq_V',
    unit: 'V',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorVoltage,
    dbcSignalName: 'vd_v',
    metricName: 'Motor_Vd_V',
    unit: 'V',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorFaults,
    dbcSignalName: 'fault_flags',
    metricName: 'MC_Fault_Flags',
    unit: 'bitfield',
  ),
  CanTelemetryBinding(
    canId: CanIds.motorFaults,
    dbcSignalName: 'sw_faults',
    metricName: 'MC_Software_Faults',
    unit: 'bitfield',
  ),
];

CanTelemetryBinding? canTelemetryBindingFor(int canId, String signalName) {
  for (final binding in canTelemetryBindings) {
    if (binding.canId == canId && binding.dbcSignalName == signalName) {
      return binding;
    }
  }
  return null;
}

class CanBindings {
  final DashboardState state;
  final MqttService mqttService;
  final GpsSourceManager gpsSourceManager;

  int _externalGpsSatellites = 0;
  bool _externalGpsLocked = false;
  bool _externalGpsStatusSeen = false;
  bool _externalGpsPositionValid = false;
  bool _externalGpsMotionValid = false;
  double? _externalGpsLat;
  double? _externalGpsLon;
  double? _externalGpsSpeedKmh;
  double? _externalGpsHeadingDeg;

  CanBindings(this.state, this.mqttService, this.gpsSourceManager);

  void handle(DecodedCanMessage message, {required DateTime receivedAtUtc}) {
    switch (message.canId) {
      case CanIds.pedalStatus:
        state.updatePedal(
          throttlePercent: _bindingValue(message, 'throttle_command'),
          isBrakePressed: message.value('brake_active') >= 0.5,
          isDeadmanActive: message.value('deadman_active') >= 0.5,
        );
        _publishSignals(message, const <String>[
          'throttle_command',
          'brake_active',
          'deadman_active',
        ]);
        break;

      case CanIds.auxCommand:
        state.updateAux(
          leftTurn: message.value('left_turn') >= 0.5,
          rightTurn: message.value('right_turn') >= 0.5,
          headlights: message.value('headlights') >= 0.5,
          hazards: message.value('hazards') >= 0.5,
          horn: message.value('horn') >= 0.5,
          wipers: message.value('wipers') >= 0.5,
        );
        break;

      case CanIds.packPower:
        final voltage = message.value('voltage_v');
        final current = message.value('current_a');
        state.updatePackPower(voltage: voltage, current: current);
        _publishSignals(message, const <String>['voltage_v', 'current_a']);
        break;

      case CanIds.auxPower:
        final voltage = message.value('voltage_v');
        final current = message.value('current_a');
        state.updateAuxPower(voltage: voltage, current: current);
        _publishSignals(message, const <String>['voltage_v', 'current_a']);
        break;

      case CanIds.packEnergy:
        final energy = message.value('energy_j');
        state.updateEnergy(energy);
        _publishSignals(message, const <String>['energy_j']);
        break;

      case CanIds.vehicleMotion:
        if (message.value('motion_valid') < 0.5) {
          return;
        }
        final speed = message.value('speed_kmh');
        final distanceKm = _bindingValue(message, 'trip_distance_m');
        state.updateMotion(speed, distanceKm, state.lapNumber);
        _publishSignals(message, const <String>[
          'speed_kmh',
          'trip_distance_m',
        ]);
        break;

      case CanIds.vehicleTime:
        // RTC synchronization is application policy and is not yet wired to
        // DashboardState. The generated decoder still validates this frame.
        break;

      case CanIds.gpsStatus:
        _externalGpsStatusSeen = true;
        _externalGpsSatellites = message.value('satellites').round();
        _externalGpsLocked = message.value('fix_valid') >= 0.5;
        _externalGpsPositionValid = message.value('position_valid') >= 0.5;
        _externalGpsMotionValid = message.value('motion_valid') >= 0.5;
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample(receivedAtUtc);
        _publishSignals(message, const <String>['satellites', 'fix_valid']);
        _publishSyntheticExternalGpsState();
        break;

      case CanIds.gpsPosition:
        _externalGpsLat = message.value('latitude_deg');
        _externalGpsLon = message.value('longitude_deg');
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample(receivedAtUtc);
        _publishSignals(message, const <String>[
          'latitude_deg',
          'longitude_deg',
        ]);
        break;

      case CanIds.gpsMotion:
        _externalGpsSpeedKmh = message.value('gps_speed_kmh');
        _externalGpsHeadingDeg = message.value('heading_deg');
        gpsSourceManager.markExternalHeartbeat();
        _tryEmitExternalGpsSample(receivedAtUtc);
        _publishSignals(message, const <String>[
          'gps_speed_kmh',
          'heading_deg',
        ]);
        break;

      case CanIds.motorState:
        _publishSignals(message, const <String>[
          'motor_speed_rpm',
          'sequencer_state',
          'motor_status',
        ]);
        break;

      case CanIds.motorCurrent:
        _publishSignals(message, const <String>[
          'iq_a',
          'id_a',
          'motor_current_a',
        ]);
        break;

      case CanIds.motorVoltage:
        _publishSignals(message, const <String>[
          'dc_bus_voltage_v',
          'vq_v',
          'vd_v',
        ]);
        break;

      case CanIds.motorFaults:
        final faultFlags = message.value('fault_flags').round();
        final softwareFaults = message.value('sw_faults').round();
        state.updateMotorFaults(
          faultFlags: faultFlags,
          softwareFaults: softwareFaults,
        );
        _publishSignals(message, const <String>['fault_flags', 'sw_faults']);
        break;

      case CanIds.motorEstimator:
      case CanIds.motorPhaseCurrent:
        // Diagnostic-only signals are decoded and visible in the generated
        // database, but are not part of the normal race telemetry stream.
        break;
    }
  }

  double _bindingValue(DecodedCanMessage message, String signalName) {
    final binding = canTelemetryBindingFor(message.canId, signalName);
    if (binding == null) {
      throw StateError(
        'No telemetry binding for 0x${message.canId.toRadixString(16)} '
        '$signalName',
      );
    }
    return binding.transformValue(message.value(signalName));
  }

  void _publishSignals(DecodedCanMessage message, List<String> signalNames) {
    for (final signalName in signalNames) {
      final binding = canTelemetryBindingFor(message.canId, signalName);
      if (binding == null) {
        continue;
      }
      mqttService.publish(
        binding.metricName,
        binding.transformValue(message.value(signalName)),
        source: binding.source,
        unit: binding.unit,
        canId: message.canId,
      );
    }
  }

  void _publishSyntheticExternalGpsState() {
    mqttService.publish(
      'GPS_Fallback_Active',
      0.0,
      source: 'external_gps',
      unit: 'bool',
      canId: CanIds.gpsStatus,
    );
    mqttService.publish(
      'GPS_Fallback_Period_Ms',
      state.gpsFallbackPeriodMs.toDouble(),
      source: 'external_gps',
      unit: 'ms',
      canId: CanIds.gpsStatus,
    );
  }

  void _tryEmitExternalGpsSample(DateTime receivedAtUtc) {
    final lat = _externalGpsLat;
    final lon = _externalGpsLon;
    final speed = _externalGpsSpeedKmh;
    final heading = _externalGpsHeadingDeg;

    if (!_externalGpsStatusSeen ||
        !_externalGpsLocked ||
        !_externalGpsPositionValid ||
        !_externalGpsMotionValid ||
        lat == null ||
        lon == null ||
        speed == null ||
        heading == null) {
      return;
    }

    gpsSourceManager.ingestExternalSample(
      satellites: _externalGpsSatellites,
      locked: _externalGpsLocked,
      lat: lat,
      lon: lon,
      headingDeg: heading,
      speedKmh: speed,
      timestampUtc: receivedAtUtc,
    );
  }
}
