import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/mqtt_payload_contract.dart';
import 'package:telemetry_dashboard/services/mqtt_service.dart';

void main() {
  group('MqttService canonical contract', () {
    test('builds canonical payload with event metadata', () {
      final state = DashboardState();
      final service = MqttService(state);

      final payload = service.buildCanonicalBatchContract(
        metricName: 'Speed_Kmh',
        value: 31.5,
        source: 'external_gps',
        unit: 'km/h',
        canId: 0x500,
      );

      expect(payload.schemaVersion, telemetryEventSchemaVersion);
      expect(payload.sessionId, isNotEmpty);
      expect(payload.events.length, 1);
      expect(payload.events.first.metricKey, 'Speed_Kmh');
      expect(payload.events.first.value, 31.5);
      expect(payload.events.first.source, 'external_gps');
      expect(payload.events.first.unit, 'km/h');
      expect(payload.events.first.canId, 0x500);
      expect(payload.events.first.sessionState, state.sessionState);
      expect(payload.events.first.lapPhase, state.lapPhase);
      expect(payload.events.first.seqInSession, 1);

      state.dispose();
    });

    test('sequence increments and resets on session change', () {
      final state = DashboardState();
      final service = MqttService(state);

      final first = service.buildCanonicalBatchContract(
        metricName: 'Voltage_780',
        value: 72.1,
      );
      final second = service.buildCanonicalBatchContract(
        metricName: 'Current_780',
        value: 4.2,
      );

      expect(first.events.first.seqInSession, 1);
      expect(second.events.first.seqInSession, 2);

      state.startSession('Session Reset Test');

      final afterSessionChange = service.buildCanonicalBatchContract(
        metricName: 'Current_780',
        value: 4.3,
      );

      expect(state.sessionId, isNotEmpty);
      expect(afterSessionChange.sessionId, state.sessionId);
      expect(afterSessionChange.events.first.seqInSession, 1);

      state.dispose();
    });
  });
}
