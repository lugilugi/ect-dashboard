import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';
import 'package:telemetry_dashboard/providers/app_providers.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/ui/widgets/service/config_view.dart';

void main() {
  group('DashboardState connection settings', () {
    test('USB port selection notifies and invokes the service callback', () {
      final state = DashboardState();
      final applied = <String>[];
      state.onUsbPortSelectionChanged = applied.add;

      expect(state.usbPortSelection, '');
      state.updateUsbPortSelection('COM5');

      expect(state.usbPortSelection, 'COM5');
      expect(applied, ['COM5']);

      // Duplicate selection is a no-op (no callback, no notify).
      var notifications = 0;
      state.addListener(() => notifications += 1);
      state.updateUsbPortSelection('COM5');
      expect(notifications, 0);

      state.updateUsbPortSelection('');
      expect(state.usbPortSelection, '');
      expect(applied, ['COM5', '']);

      state.dispose();
    });

    test('MQTT port is clamped to the valid range', () {
      final state = DashboardState();

      expect(state.mqttPort, 1883);
      state.updateMqttPort(0);
      expect(state.mqttPort, 1);
      state.updateMqttPort(99999);
      expect(state.mqttPort, 65535);
      state.updateMqttPort(1884);
      expect(state.mqttPort, 1884);

      state.dispose();
    });

    test('USB baud rate notifies and invokes the service callback', () {
      final state = DashboardState();
      final applied = <int>[];
      state.onUsbBaudRateChanged = applied.add;

      expect(state.usbBaudRate, 115200);
      state.updateUsbBaudRate(500000);

      expect(state.usbBaudRate, 500000);
      expect(applied, [500000]);

      // Out-of-range values are clamped.
      state.updateUsbBaudRate(1);
      expect(state.usbBaudRate, 1200);

      // Duplicate selection is a no-op (no callback, no notify).
      var notifications = 0;
      state.addListener(() => notifications += 1);
      state.updateUsbBaudRate(1200);
      expect(notifications, 0);

      state.updateUsbBaudRate(115200);
      expect(state.usbBaudRate, 115200);
      expect(applied, [500000, 1200, 115200]);

      state.dispose();
    });
  });

  group('Config connectivity section', () {
    testWidgets('renders USB port select and MQTT endpoint cards', (tester) async {
      final state = DashboardState();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [dashboardStateProvider.overrideWith((ref) => state)],
          child: MaterialApp(
            home: Scaffold(
              body: ConfigView(p: Palette(false)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('USB PORT SELECT'), findsOneWidget);
      expect(find.text('USB SERIAL BAUD RATE'), findsOneWidget);
      expect(find.text('MQTT ENDPOINT'), findsOneWidget);
      expect(find.text('AUTO DETECT'), findsOneWidget);
    });

    testWidgets('changing the baud dropdown updates state', (tester) async {
      final state = DashboardState();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [dashboardStateProvider.overrideWith((ref) => state)],
          child: MaterialApp(
            home: Scaffold(
              body: ConfigView(p: Palette(false)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(state.usbBaudRate, 115200);
      await tester.tap(find.text('115200'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('500000').last);
      await tester.pumpAndSettle();

      expect(state.usbBaudRate, 500000);
    });

    testWidgets('applying an MQTT endpoint updates state', (tester) async {
      final state = DashboardState();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [dashboardStateProvider.overrideWith((ref) => state)],
          child: MaterialApp(
            home: Scaffold(
              body: ConfigView(p: Palette(false)),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.widgetWithText(TextField, 'Broker host'), 'pitwall');
      await tester.enterText(find.widgetWithText(TextField, 'Port'), '1884');
      await tester.ensureVisible(find.text('APPLY'));
      await tester.tap(find.text('APPLY'));
      await tester.pump();

      expect(state.mqttHost, 'pitwall');
      expect(state.mqttPort, 1884);
    });
  });
}
