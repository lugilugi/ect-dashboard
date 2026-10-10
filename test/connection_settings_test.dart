import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';
import 'package:telemetry_dashboard/providers/app_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/ingest/ingest_transport.dart';
import 'package:telemetry_dashboard/services/persistence/app_preferences_service.dart';
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

    test('link mode notifies and invokes the service callback', () {
      final state = DashboardState()..bleLinkSupported = true;
      final applied = <LinkMode>[];
      state.onLinkModeChanged = applied.add;

      expect(state.linkMode, LinkMode.usb);
      state.updateLinkMode(LinkMode.ble);
      expect(state.linkIsBle, isTrue);

      var notifications = 0;
      state.addListener(() => notifications += 1);
      state.updateLinkMode(LinkMode.ble);
      expect(notifications, 0);

      state.updateLinkMode(LinkMode.usb);
      expect(applied, [LinkMode.ble, LinkMode.usb]);

      state.dispose();
    });

    test('BLE link mode falls back to USB where unsupported', () {
      final state = DashboardState()..bleLinkSupported = false;
      final applied = <LinkMode>[];
      state.onLinkModeChanged = applied.add;

      state.updateLinkMode(LinkMode.ble);
      expect(state.linkMode, LinkMode.usb);
      expect(applied, isEmpty);

      state.dispose();
    });

    test('BLE device selection is kept apart from the USB pin', () {
      final state = DashboardState();
      final applied = <String>[];
      state.onBleDeviceSelectionChanged = applied.add;

      state.updateUsbPortSelection('COM5');
      state.updateBleDeviceSelection('AA:BB:CC:DD:EE:FF');

      expect(state.usbPortSelection, 'COM5');
      expect(state.bleDeviceSelection, 'AA:BB:CC:DD:EE:FF');
      expect(applied, ['AA:BB:CC:DD:EE:FF']);

      state.dispose();
    });

    test('link mode and BLE device persist across restarts', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = AppPreferencesService();

      final saved = DashboardState()..bleLinkSupported = true;
      saved.updateLinkMode(LinkMode.ble);
      saved.updateBleDeviceSelection('AA:BB:CC:DD:EE:FF');
      await prefs.saveFromState(saved);

      final restored = DashboardState()..bleLinkSupported = true;
      await prefs.restoreIntoState(restored);
      expect(restored.linkMode, LinkMode.ble);
      expect(restored.bleDeviceSelection, 'AA:BB:CC:DD:EE:FF');
      expect(
        prefs.buildStateSignature(restored),
        prefs.buildStateSignature(saved),
      );

      final desktop = DashboardState()..bleLinkSupported = false;
      await prefs.restoreIntoState(desktop);
      expect(desktop.linkMode, LinkMode.usb);
      expect(desktop.bleDeviceSelection, 'AA:BB:CC:DD:EE:FF');

      saved.dispose();
      restored.dispose();
      desktop.dispose();
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

    testWidgets('BLE link mode swaps USB port controls for BLE pairing', (
      tester,
    ) async {
      final state = DashboardState()..bleLinkSupported = true;

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

      expect(find.text('VEHICLE LINK'), findsOneWidget);
      await tester.tap(find.text('BLE'));
      await tester.pumpAndSettle();

      expect(state.linkMode, LinkMode.ble);
      expect(find.text('BLE DEVICE'), findsOneWidget);
      expect(find.text('PAIR'), findsOneWidget);
      expect(find.text('USB PORT SELECT'), findsNothing);
      expect(find.text('USB SERIAL BAUD RATE'), findsNothing);
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
