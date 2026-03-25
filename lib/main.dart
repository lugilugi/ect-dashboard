import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/dashboard_state.dart';
import 'services/usb_service.dart';
import 'services/api_service.dart';
import 'ui/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]).then((_) {
    runApp(
      ChangeNotifierProvider(
        create: (context) => DashboardState(),
        child: const TelemetryApp(),
      ),
    );
  });
}

class TelemetryApp extends StatefulWidget {
  const TelemetryApp({super.key});

  @override
  State<TelemetryApp> createState() => _TelemetryAppState();
}

class _TelemetryAppState extends State<TelemetryApp> {
  late UsbService _usbService;
  late ApiService _apiService;

  @override
  void initState() {
    super.initState();
    // Initialize USB Service and start listening
    final state = Provider.of<DashboardState>(context, listen: false);
    _usbService = UsbService(state);
    state.onUsbTx = _usbService.sendString;
    _usbService.start();
    
    // Initialize API Service
    _apiService = ApiService(state);
    _apiService.start();
  }

  @override
  void dispose() {
    _apiService.stop();
    _usbService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DashboardState>();

    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF121212),
      primaryColor: Colors.blueAccent,
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.white),
        titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.white70),
        bodyMedium: TextStyle(fontSize: 18, color: Colors.white54),
      ),
    );

    final lightTheme = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      primaryColor: Colors.blueAccent,
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.black),
        titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.black87),
        bodyMedium: TextStyle(fontSize: 18, color: Colors.black54),
      ),
    );

    return MaterialApp(
      title: 'Telemetry Dashboard',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child!,
        );
      },
      theme: state.useLightTheme ? lightTheme : darkTheme,
      home: const DashboardScreen(),
    );
  }
}
