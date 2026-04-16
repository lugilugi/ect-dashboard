import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry_event.dart';
import 'package:telemetry_dashboard/services/mqtt_payload_contract.dart';

void main() {
  group('Phase 0 wire contracts', () {
    test('enum wire values round-trip', () {
      for (final mode in UiMode.values) {
        expect(UiModeWire.fromWire(mode.wireValue), equals(mode));
      }

      for (final state in SessionState.values) {
        expect(SessionStateWire.fromWire(state.wireValue), equals(state));
      }

      for (final phase in LapPhase.values) {
        expect(LapPhaseWire.fromWire(phase.wireValue), equals(phase));
      }
    });

    test('session control state json round-trip', () {
      const control = SessionControlState(
        sessionState: SessionState.logging,
        uiMode: UiMode.driver,
        lapsPlanned: 10,
        lapsCompleted: 3,
        lapPhase: LapPhase.crossingDeadzone,
        crossingDeadzoneMs: 3000,
        crossingDeadzoneRemainingMs: 1500,
        crossingValid: true,
      );

      final encoded = control.toJson();
      final decoded = SessionControlState.fromJson(encoded);

      expect(decoded.sessionState, equals(control.sessionState));
      expect(decoded.uiMode, equals(control.uiMode));
      expect(decoded.lapsPlanned, equals(control.lapsPlanned));
      expect(decoded.lapsCompleted, equals(control.lapsCompleted));
      expect(decoded.lapPhase, equals(control.lapPhase));
      expect(decoded.crossingDeadzoneMs, equals(control.crossingDeadzoneMs));
      expect(
        decoded.crossingDeadzoneRemainingMs,
        equals(control.crossingDeadzoneRemainingMs),
      );
      expect(decoded.crossingValid, equals(control.crossingValid));
    });

    test('decoded metric event json round-trip', () {
      final event = DecodedMetricEvent(
        metricKey: 'Speed_Kmh',
        value: 34.2,
        unit: 'km/h',
        sessionId: '0f87e3b8-01c8-4dd8-9b9b-4f5dd9d79b9a',
        lapNumber: 2,
        sessionState: SessionState.logging,
        lapPhase: LapPhase.running,
        tsWallUtc: DateTime.utc(2026, 4, 16, 8, 15, 30, 120),
        tsSessionMs: 45678,
        source: 'external_gps',
        canId: 0x500,
        seqInSession: 990,
        qualityFlag: 'ok',
        receivedAtUsMono: 123456789,
      );

      final encoded = event.toJson();
      final decoded = DecodedMetricEvent.fromJson(encoded);

      expect(decoded.metricKey, equals(event.metricKey));
      expect(decoded.value, equals(event.value));
      expect(decoded.unit, equals(event.unit));
      expect(decoded.sessionId, equals(event.sessionId));
      expect(decoded.lapNumber, equals(event.lapNumber));
      expect(decoded.sessionState, equals(event.sessionState));
      expect(decoded.lapPhase, equals(event.lapPhase));
      expect(decoded.tsWallUtc, equals(event.tsWallUtc));
      expect(decoded.tsSessionMs, equals(event.tsSessionMs));
      expect(decoded.source, equals(event.source));
      expect(decoded.canId, equals(event.canId));
      expect(decoded.seqInSession, equals(event.seqInSession));
      expect(decoded.qualityFlag, equals(event.qualityFlag));
      expect(decoded.receivedAtUsMono, equals(event.receivedAtUsMono));
    });

    test('telemetry event batch payload round-trip', () {
      final event = DecodedMetricEvent(
        metricKey: 'Voltage_780',
        value: 72.4,
        unit: 'V',
        sessionId: 'f6a1c4ac-6458-4ecf-9f1a-feb3f3068d75',
        lapNumber: 1,
        sessionState: SessionState.logging,
        lapPhase: LapPhase.running,
        tsWallUtc: DateTime.utc(2026, 4, 16, 8, 20, 0),
        tsSessionMs: 12000,
        source: 'can',
        canId: 0x310,
        seqInSession: 5,
      );

      final payload = TelemetryEventBatchPayload(
        schemaVersion: telemetryEventSchemaVersion,
        batchId: 'e22859d0-6b8c-4eb5-bf35-4df60f58f47b',
        sessionId: event.sessionId,
        sessionState: SessionState.logging,
        createdAtUtc: DateTime.utc(2026, 4, 16, 8, 20, 1),
        lapsPlanned: 10,
        lapsCompleted: 1,
        events: [event],
      );

      final encoded = payload.toJson();
      final decoded = TelemetryEventBatchPayload.fromJson(encoded);

      expect(decoded.schemaVersion, equals(payload.schemaVersion));
      expect(decoded.batchId, equals(payload.batchId));
      expect(decoded.sessionId, equals(payload.sessionId));
      expect(decoded.sessionState, equals(payload.sessionState));
      expect(decoded.createdAtUtc, equals(payload.createdAtUtc));
      expect(decoded.lapsPlanned, equals(payload.lapsPlanned));
      expect(decoded.lapsCompleted, equals(payload.lapsCompleted));
      expect(decoded.events.length, equals(1));
      expect(decoded.events.first.metricKey, equals(event.metricKey));
      expect(decoded.events.first.seqInSession, equals(event.seqInSession));
    });
  });
}