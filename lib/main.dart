import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/app_providers.dart';
import 'repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_runtime_coordinator.dart';
import 'package:telemetry_dashboard/ui/screens/dashboard_screen.dart';

import 'dart:convert';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:usb_serial/usb_serial.dart';


final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        name: 'dashboard',
        builder: (context, state) {
          return const _RuntimeRouteEntry();
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]).then((_) {
    runApp(const ProviderScope(child: TelemetryBootstrapApp()));
  });
}

class TelemetryBootstrapApp extends ConsumerWidget {
  const TelemetryBootstrapApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useLightTheme = ref.watch(useLightThemeProvider);
    final router = ref.watch(appRouterProvider);

    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF121212),
      primaryColor: Colors.blueAccent,
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 72,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        titleLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Colors.white70,
        ),
        bodyMedium: TextStyle(fontSize: 18, color: Colors.white54),
      ),
    );

    final lightTheme = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      primaryColor: Colors.blueAccent,
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 72,
          fontWeight: FontWeight.bold,
          color: Colors.black,
        ),
        titleLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        bodyMedium: TextStyle(fontSize: 18, color: Colors.black54),
      ),
    );

    return MaterialApp.router(
      title: 'Eco Archers Dashboard',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child!,
        );
      },
      theme: useLightTheme ? lightTheme : darkTheme,
      routerConfig: router,
    );
  }
}

class _RuntimeRouteEntry extends ConsumerWidget {
  const _RuntimeRouteEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canIngestRepository = ref.watch(canIngestRepositoryProvider);
    return TelemetryApp(canIngestRepository: canIngestRepository);
  }
}

class TelemetryApp extends ConsumerStatefulWidget {
  final CanIngestRepository canIngestRepository;

  const TelemetryApp({required this.canIngestRepository, super.key});

  @override
  ConsumerState<TelemetryApp> createState() => _TelemetryAppState();
}

class _TelemetryAppState extends ConsumerState<TelemetryApp> {
  TelemetryRuntimeCoordinator? _runtimeCoordinator;

  @override
  void initState() {
    super.initState();

    final state = ref.read(dashboardStateProvider);

    _runtimeCoordinator = TelemetryRuntimeCoordinator(
      state: state,
      canIngestRepository: widget.canIngestRepository,
    );

    // Auto-detect device and use the correct serial method
    if (Platform.isAndroid) {
      // Use this if phone ang gamit
      listenToEsp32Android(widget.canIngestRepository);
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // Use this if laptop ang gamit
      listenToEsp32(widget.canIngestRepository, 'COM3');//change com port if not com 3 gamit
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final runtimeCoordinator = _runtimeCoordinator;
      if (!mounted || runtimeCoordinator == null) {
        return;
      }
      unawaited(runtimeCoordinator.start());
    });
  }

  @override
  void dispose() {
    _runtimeCoordinator?.dispose();
    _runtimeCoordinator = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const DashboardScreen();
  }
}

void listenToEsp32(CanIngestRepository repo, String comPort) {
  final port = SerialPort(comPort);
  
  if (!port.openRead()) {
    debugPrint('Failed to open serial port $comPort: ${SerialPort.lastError}');
    return;
  }

  // Ensure the baud rate matches your ESP32's Serial.begin()
  final config = port.config;
  config.baudRate = 115200; // Change to 500000 if you set that in ESP-IDF
  port.config = config;

  final reader = SerialPortReader(port);
  String buffer = '';

  reader.stream.listen((Uint8List data) {
    buffer += utf8.decode(data);
    final lines = buffer.split('\n');
    
    // Keep the last incomplete line in the buffer until the next chunk arrives
    buffer = lines.removeLast();

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        // Feed the perfectly formatted string into the dashboard's parser
        repo.ingestLine(trimmed, source: comPort);
      }
    }
  });
}

Future<void> listenToEsp32Android(CanIngestRepository repo) async {
  //Find connected USB devices
  List<UsbDevice> devices = await UsbSerial.listDevices();
  if (devices.isEmpty) {
    debugPrint('No USB devices found on phone.');
    return;
  }

  //Connect to the first available device (your ESP32)
  UsbPort? port = await devices.first.create();
  if (port == null) return;

  bool openResult = await port.open();
  if (!openResult) {
    debugPrint('Failed to open Android USB port.');
    return;
  }

  //Configure CDC parameters
  await port.setDTR(true);
  await port.setRTS(true);
  port.setPortParameters(115200, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

  String buffer = '';

  //Listen to the stream just like on Windows
  port.inputStream!.listen((Uint8List data) {
    buffer += utf8.decode(data);
    final lines = buffer.split('\n');
    
    buffer = lines.removeLast();

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        repo.ingestLine(trimmed, source: 'android_otg');
      }
    }
  });
}
