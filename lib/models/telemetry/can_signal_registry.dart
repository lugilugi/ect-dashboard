import 'can_messages.dart';

// =============================================================================
// CAN SIGNAL REGISTRY
//
// Single source of truth for every telemetry signal the app publishes over
// MQTT. The backend is schema-agnostic (narrow EAV rows), so adding or
// removing a signal NEVER requires a database change - edit this registry
// (plus the decode case in UsbService._dispatchPayload) and it flows
// straight through to TimescaleDB and Grafana.
//
// Adding a new CAN message/signal:
//   1. Declare the CAN ID in CanMsgID (can_messages.dart) if new.
//   2. Add a CanSignalSpec entry below (or a list, one per signal).
//   3. Add/extend the switch case in UsbService._dispatchPayload to decode
//      the payload bytes and publish values via _publishSignals(...).
// Removing a signal: delete its registry entry and its publish line.
// =============================================================================

class CanSignalSpec {
  final int canId;
  final String signalName;
  final String unit;
  final String source;

  const CanSignalSpec({
    required this.canId,
    required this.signalName,
    required this.unit,
    this.source = 'can',
  });
}

/// Every signal emitted by the CAN bridge, keyed by CAN ID.
const List<CanSignalSpec> canSignalRegistry = <CanSignalSpec>[
  // 0x110 PEDAL
  CanSignalSpec(
    canId: CanMsgID.pedal,
    signalName: 'Throttle_Percent',
    unit: '%',
  ),
  CanSignalSpec(
    canId: CanMsgID.pedal,
    signalName: 'Brake_Active',
    unit: 'bool',
  ),

  // 0x310 / 0x311 POWER MONITOR (780 and 740 current scaling)
  CanSignalSpec(
    canId: CanMsgID.pwrMonitor780,
    signalName: 'Voltage_780',
    unit: 'V',
  ),
  CanSignalSpec(
    canId: CanMsgID.pwrMonitor780,
    signalName: 'Current_780',
    unit: 'A',
  ),
  CanSignalSpec(
    canId: CanMsgID.pwrMonitor740,
    signalName: 'Voltage_740',
    unit: 'V',
  ),
  CanSignalSpec(
    canId: CanMsgID.pwrMonitor740,
    signalName: 'Current_740',
    unit: 'A',
  ),

  // 0x312 ENERGY COUNTER
  CanSignalSpec(
    canId: CanMsgID.pwrEnergy,
    signalName: 'Joules_780',
    unit: 'J',
  ),
  CanSignalSpec(
    canId: CanMsgID.pwrEnergy,
    signalName: 'Joules_740',
    unit: 'J',
  ),

  // 0x400 DASHBOARD STATUS
  CanSignalSpec(
    canId: CanMsgID.dashStat,
    signalName: 'Error_Count',
    unit: 'count',
  ),
  CanSignalSpec(
    canId: CanMsgID.dashStat,
    signalName: 'MC_Temp_C',
    unit: 'C',
  ),
  CanSignalSpec(
    canId: CanMsgID.dashStat,
    signalName: 'Batt_Temp_C',
    unit: 'C',
  ),

  // 0x500 HALL SPEED / DISTANCE
  CanSignalSpec(
    canId: CanMsgID.hallStat,
    signalName: 'Speed_Kmh',
    unit: 'km/h',
  ),
  CanSignalSpec(
    canId: CanMsgID.hallStat,
    signalName: 'Distance_Km',
    unit: 'km',
  ),

  // 0x510 GPS FIX
  CanSignalSpec(
    canId: CanMsgID.gpsFix,
    signalName: 'GPS_Satellites',
    unit: 'count',
    source: 'external_gps',
  ),
  CanSignalSpec(
    canId: CanMsgID.gpsFix,
    signalName: 'GPS_Locked',
    unit: 'bool',
    source: 'external_gps',
  ),
  CanSignalSpec(
    canId: CanMsgID.gpsFix,
    signalName: 'GPS_Fallback_Active',
    unit: 'bool',
    source: 'external_gps',
  ),
  CanSignalSpec(
    canId: CanMsgID.gpsFix,
    signalName: 'GPS_Fallback_Period_Ms',
    unit: 'ms',
    source: 'external_gps',
  ),

  // 0x511 GPS POSITION
  CanSignalSpec(
    canId: CanMsgID.gpsPosition,
    signalName: 'GPS_Latitude_Deg',
    unit: 'deg',
    source: 'external_gps',
  ),
  CanSignalSpec(
    canId: CanMsgID.gpsPosition,
    signalName: 'GPS_Longitude_Deg',
    unit: 'deg',
    source: 'external_gps',
  ),

  // 0x512 GPS MOTION
  CanSignalSpec(
    canId: CanMsgID.gpsMotion,
    signalName: 'GPS_Speed_Kmh',
    unit: 'km/h',
    source: 'external_gps',
  ),
  CanSignalSpec(
    canId: CanMsgID.gpsMotion,
    signalName: 'GPS_Heading_Deg',
    unit: 'deg',
    source: 'external_gps',
  ),
];

CanSignalSpec? canSignalSpecByName(String signalName) {
  for (final spec in canSignalRegistry) {
    if (spec.signalName == signalName) {
      return spec;
    }
  }
  return null;
}
