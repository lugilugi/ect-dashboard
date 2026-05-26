import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';
import 'package:telemetry_dashboard/services/orchestration/session_checkpoint_service.dart';

class _FakeMqttTransport implements MqttTransport {
  bool _connected = false;
  void Function()? _onConnected;
  void Function()? _onDisconnected;

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
    _connected = true;
    _onConnected?.call();
  }

  @override
  void disconnect() {
    _connected = false;
    _onDisconnected?.call();
  }

  @override
  bool get isConnected {
    return _connected;
  }

  @override
  bool publish({required String topic, required String payloadJson}) {
    return _connected;
  }
}

Future<void> _drainMicrotasks([int ticks = 10]) async {
  for (int i = 0; i < ticks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('SessionCheckpointService', () {
    test('restores recoverable checkpoint and seeds MQTT sequence', () async {
      final state = DashboardState();
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 64,
      );
      state.attachSpoolHealthStore(spool.spoolHealth);
      final transport = _FakeMqttTransport();
      final mqtt = MqttService(
        state,
        localSpoolService: spool,
        transport: transport,
      );

      final snapshot = SessionCheckpointSnapshot(
        sessionId: 'session-restore-1',
        sessionName: 'Recovered Session',
        sessionState: SessionState.logging,
        uiMode: UiMode.driver,
        lapsCompleted: 2,
        lapPhase: LapPhase.running,
        crossingDeadzoneMs: 3000,
        crossingDeadzoneRemainingMs: 0,
        crossingValid: false,
        lapNumber: 3,
        sessionTimeSeconds: 87,
        lastSeqInSession: 41,
        gpsLocked: true,
        usingPhoneGpsFallback: false,
        updatedAtUtc: DateTime.now().toUtc(),
      );

      await spool.saveSessionCheckpoint(
        checkpointJson: jsonEncode(snapshot.toJson()),
      );

      final service = SessionCheckpointService(
        state: state,
        localSpoolService: spool,
        mqttService: mqtt,
      );

      await service.start();
      await _drainMicrotasks();

      expect(service.restoreApplied, isTrue);
      expect(state.sessionId, snapshot.sessionId);
      expect(state.sessionName, snapshot.sessionName);
      expect(state.sessionState, SessionState.logging);
      expect(state.lapNumber, snapshot.lapNumber);
      expect(state.sessionTimeSeconds, snapshot.sessionTimeSeconds);
      expect(state.recoveryResumeCount, 1);
      expect(state.lastRecoveryAtUtc, isNotNull);

      // Sequence should continue from checkpoint and reserve one slot for the recovery event.
      expect(mqtt.sequenceForCheckpoint, 42);
      expect(await spool.pendingDecodedEventCount(), 1);
      expect(await spool.pendingCount(), 1);

      // Recovered sessions must drain replay backlog before normal stop is accepted.
      state.updateMqttBacklog(
        count: 1,
        oldestEnqueuedAtUtc: DateTime.now().toUtc(),
      );
      expect(state.stopSession(), isFalse);
      expect(state.endBlockReason, contains('replay backlog'));

      state.updateMqttBacklog(count: 0, oldestEnqueuedAtUtc: null);
      expect(state.stopSession(), isTrue);
      expect(state.sessionState, SessionState.ended);

      // Abort remains available even when backlog is non-zero.
      state.restoreFromCheckpoint(snapshot);
      state.updateMqttBacklog(
        count: 1,
        oldestEnqueuedAtUtc: DateTime.now().toUtc(),
      );
      expect(state.stopSession(abort: true), isTrue);

      service.stop();
      state.dispose();
      await spool.close();
    });

    test('restores sequence from spool watermark when checkpoint lags', () async {
      final state = DashboardState();
      final spool = LocalSpoolService(
        forceInMemory: true,
        maxPendingBatches: 64,
      );
      state.attachSpoolHealthStore(spool.spoolHealth);
      final transport = _FakeMqttTransport();
      final mqtt = MqttService(
        state,
        localSpoolService: spool,
        transport: transport,
      );

      final snapshot = SessionCheckpointSnapshot(
        sessionId: 'session-restore-2',
        sessionName: 'Recovered Session Lagged Checkpoint',
        sessionState: SessionState.logging,
        uiMode: UiMode.driver,
        lapsCompleted: 3,
        lapPhase: LapPhase.running,
        crossingDeadzoneMs: 3000,
        crossingDeadzoneRemainingMs: 0,
        crossingValid: false,
        lapNumber: 4,
        sessionTimeSeconds: 112,
        lastSeqInSession: 41,
        gpsLocked: true,
        usingPhoneGpsFallback: false,
        updatedAtUtc: DateTime.now().toUtc(),
      );

      await spool.saveSessionCheckpoint(
        checkpointJson: jsonEncode(snapshot.toJson()),
      );
      await spool.enqueueDecodedEvent(
        sessionId: snapshot.sessionId,
        seqInSession: 50,
        eventJson: '{"metric_key":"Speed_Kmh"}',
      );

      final service = SessionCheckpointService(
        state: state,
        localSpoolService: spool,
        mqttService: mqtt,
      );

      await service.start();
      await _drainMicrotasks();

      expect(service.restoreApplied, isTrue);
      expect(state.sessionId, snapshot.sessionId);
      expect(state.recoveryResumeCount, 1);

      // Resume should use the spool high watermark (50), then emit recovery at 51.
      expect(mqtt.sequenceForCheckpoint, 51);
      expect(await spool.pendingDecodedEventCount(), 2);
      expect(await spool.pendingCount(), 1);

      service.stop();
      state.dispose();
      await spool.close();
    });

    test(
      'keeps sequence monotonic across repeated restart recoveries',
      () async {
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 64,
        );

        final baseSnapshot = SessionCheckpointSnapshot(
          sessionId: 'session-restart-loop-1',
          sessionName: 'Restart Loop Session',
          sessionState: SessionState.logging,
          uiMode: UiMode.driver,
          lapsCompleted: 2,
          lapPhase: LapPhase.running,
          crossingDeadzoneMs: 3000,
          crossingDeadzoneRemainingMs: 0,
          crossingValid: false,
          lapNumber: 3,
          sessionTimeSeconds: 95,
          lastSeqInSession: 17,
          gpsLocked: true,
          usingPhoneGpsFallback: false,
          updatedAtUtc: DateTime.now().toUtc(),
        );

        await spool.saveSessionCheckpoint(
          checkpointJson: jsonEncode(baseSnapshot.toJson()),
        );
        await spool.enqueueDecodedEvent(
          sessionId: baseSnapshot.sessionId,
          seqInSession: 20,
          eventJson: '{"metric_key":"Speed_Kmh"}',
        );

        final firstState = DashboardState();
        firstState.attachSpoolHealthStore(spool.spoolHealth);
        final firstMqtt = MqttService(
          firstState,
          localSpoolService: spool,
          transport: _FakeMqttTransport(),
        );
        final firstService = SessionCheckpointService(
          state: firstState,
          localSpoolService: spool,
          mqttService: firstMqtt,
        );

        await firstService.start();
        await _drainMicrotasks();

        expect(firstService.restoreApplied, isTrue);
        expect(firstMqtt.sequenceForCheckpoint, 21);
        expect(await spool.pendingDecodedEventCount(), 2);

        firstService.stop();
        firstState.dispose();

        final staleCheckpoint = SessionCheckpointSnapshot(
          sessionId: baseSnapshot.sessionId,
          sessionName: baseSnapshot.sessionName,
          sessionState: SessionState.logging,
          uiMode: UiMode.driver,
          lapsCompleted: baseSnapshot.lapsCompleted,
          lapPhase: baseSnapshot.lapPhase,
          crossingDeadzoneMs: baseSnapshot.crossingDeadzoneMs,
          crossingDeadzoneRemainingMs:
              baseSnapshot.crossingDeadzoneRemainingMs,
          crossingValid: baseSnapshot.crossingValid,
          lapNumber: baseSnapshot.lapNumber,
          sessionTimeSeconds: baseSnapshot.sessionTimeSeconds,
          lastSeqInSession: 12,
          gpsLocked: baseSnapshot.gpsLocked,
          usingPhoneGpsFallback: baseSnapshot.usingPhoneGpsFallback,
          updatedAtUtc: DateTime.now().toUtc(),
        );
        await spool.saveSessionCheckpoint(
          checkpointJson: jsonEncode(staleCheckpoint.toJson()),
        );

        final secondState = DashboardState();
        secondState.attachSpoolHealthStore(spool.spoolHealth);
        final secondMqtt = MqttService(
          secondState,
          localSpoolService: spool,
          transport: _FakeMqttTransport(),
        );
        final secondService = SessionCheckpointService(
          state: secondState,
          localSpoolService: spool,
          mqttService: secondMqtt,
        );

        await secondService.start();
        await _drainMicrotasks();

        expect(secondService.restoreApplied, isTrue);
        expect(secondState.sessionId, baseSnapshot.sessionId);
        expect(secondMqtt.sequenceForCheckpoint, 22);
        expect(await spool.pendingDecodedEventCount(), 3);
        expect(secondState.recoveryResumeCount, 2);

        secondService.stop();
        secondState.dispose();
        await spool.close();
      },
    );

    test(
      'persists active checkpoint and clears it after session ends',
      () async {
        final state = DashboardState();
        final spool = LocalSpoolService(
          forceInMemory: true,
          maxPendingBatches: 64,
        );
        state.attachSpoolHealthStore(spool.spoolHealth);
        final transport = _FakeMqttTransport();
        final mqtt = MqttService(
          state,
          localSpoolService: spool,
          transport: transport,
        );

        final service = SessionCheckpointService(
          state: state,
          localSpoolService: spool,
          mqttService: mqtt,
        );

        await service.start();

        final activeSnapshot = SessionCheckpointSnapshot(
          sessionId: 'session-active-1',
          sessionName: 'Active Session',
          sessionState: SessionState.logging,
          uiMode: UiMode.driver,
          lapsCompleted: 1,
          lapPhase: LapPhase.running,
          crossingDeadzoneMs: 3000,
          crossingDeadzoneRemainingMs: 0,
          crossingValid: false,
          lapNumber: 2,
          sessionTimeSeconds: 14,
          lastSeqInSession: 7,
          gpsLocked: true,
          usingPhoneGpsFallback: false,
          updatedAtUtc: DateTime.now().toUtc(),
        );

        state.restoreFromCheckpoint(activeSnapshot);
        await _drainMicrotasks();

        final checkpointJson = await spool.readSessionCheckpointJson();
        expect(checkpointJson, isNotNull);
        final decoded = SessionCheckpointSnapshot.fromJson(
          jsonDecode(checkpointJson!) as Map<String, dynamic>,
        );
        expect(decoded.sessionId, activeSnapshot.sessionId);
        expect(decoded.sessionState, SessionState.logging);

        state.resetSessionState();
        await _drainMicrotasks();

        final afterClear = await spool.readSessionCheckpointJson();
        expect(afterClear, isNull);

        service.stop();
        state.dispose();
        await spool.close();
      },
    );
  });
}
