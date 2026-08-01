import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/providers/app_providers.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/ui/screens/dashboard_screen.dart';

void main() {
  late ProviderContainer container;
  late DashboardState state;

  setUp(() {
    state = DashboardState();
    container = ProviderContainer(
      overrides: [
        dashboardStateProvider.overrideWith((ref) => state),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  Future<void> pumpDashboard(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
  }

  testWidgets('driver page renders status bar and nav controls', (tester) async {
    await pumpDashboard(tester);

    expect(find.text('DRV'), findsOneWidget);
    expect(find.text('CFG'), findsOneWidget);
    expect(find.text('HOLD'), findsOneWidget);
    expect(find.textContaining('Q:0'), findsWidgets);
  });

  testWidgets('long-press HOLD opens the start-session dialog', (tester) async {
    await pumpDashboard(tester);

    await tester.longPress(find.text('HOLD'));
    // Fixed pumps instead of pumpAndSettle: the 1s session ticker keeps
    // scheduling frames, which would make pumpAndSettle time out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('RUN NAME'), findsOneWidget);
    expect(find.text('CONFIRM & START'), findsOneWidget);

    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('RUN NAME'), findsNothing);
  });

  testWidgets('tapping CFG before entering service mode shows guidance snackbar',
      (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.text('CFG'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Long-press CFG to enter Service mode.'),
      findsOneWidget,
    );
  });
}
