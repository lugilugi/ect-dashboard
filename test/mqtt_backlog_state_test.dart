import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

void main() {
  group('DashboardState MQTT backlog', () {
    test('tracks backlog count and oldest age', () {
      final state = DashboardState();
      final oldest = DateTime.now().toUtc().subtract(const Duration(seconds: 5));

      state.updateMqttBacklog(count: 3, oldestEnqueuedAtUtc: oldest);

      expect(state.unsentBatchCount, 3);
      expect(state.oldestUnsentAgeMs, greaterThanOrEqualTo(4000));
      expect(state.oldestUnsentAgeText.endsWith('s'), isTrue);

      state.dispose();
    });

    test('clears backlog age when queue is empty', () {
      final state = DashboardState();
      final oldest = DateTime.now().toUtc().subtract(const Duration(seconds: 5));

      state.updateMqttBacklog(count: 2, oldestEnqueuedAtUtc: oldest);
      state.updateMqttBacklog(count: 0, oldestEnqueuedAtUtc: null);

      expect(state.unsentBatchCount, 0);
      expect(state.oldestUnsentAgeMs, 0);
      expect(state.oldestUnsentAgeText, '0.0s');

      state.dispose();
    });

    test('spool warning is raised near pending capacity threshold', () {
      final state = DashboardState();

      state.updateSpoolHealth(pendingBatchCount: 7, pendingBatchCapacity: 10);
      expect(state.spoolCapacityWarning, isFalse);

      state.updateSpoolHealth(pendingBatchCount: 8, pendingBatchCapacity: 10);
      expect(state.spoolCapacityWarning, isTrue);
      expect(state.spoolUsageText, '8/10');

      state.dispose();
    });
  });
}
