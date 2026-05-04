import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/app_providers.dart';
import 'repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_runtime_coordinator.dart';
import 'package:telemetry_dashboard/ui/screens/dashboard_screen.dart';

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
      title: 'Telemetry Dashboard',
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
