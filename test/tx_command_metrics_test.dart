import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

void main() {
  group('DashboardState TX metrics', () {
    test('pending count includes rejected commands as terminal', () {
      final state = DashboardState();

      state.commandSentCount = 5;
      state.commandCompletionCount = 3;
      state.commandRejectedCount = 1;

      expect(state.commandTerminalCount, 4);
      expect(state.pendingTxCommandCount, 1);

      state.dispose();
    });

    test('pending count never goes negative', () {
      final state = DashboardState();

      state.commandSentCount = 1;
      state.commandCompletionCount = 0;
      state.commandRejectedCount = 3;

      expect(state.commandTerminalCount, 3);
      expect(state.pendingTxCommandCount, 0);

      state.dispose();
    });
  });
}
