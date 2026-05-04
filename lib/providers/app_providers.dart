import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:telemetry_dashboard/repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/orchestration/session_orchestrator.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';

final dashboardStateProvider = ChangeNotifierProvider<DashboardState>((ref) {
  final state = DashboardState();
  ref.onDispose(state.dispose);
  return state;
});

final sessionControlStoreProvider = Provider<SessionControlStore>((ref) {
  return ref.watch(dashboardStateProvider).sessionControl;
});

final spoolHealthStoreProvider = Provider<SpoolHealthStore>((ref) {
  return ref.watch(dashboardStateProvider).spoolHealth;
});

final alertStateStoreProvider = Provider<AlertStateStore>((ref) {
  return ref.watch(dashboardStateProvider).alerts;
});

final readableCopyStateStoreProvider = Provider<ReadableCopyStateStore>((ref) {
  return ref.watch(dashboardStateProvider).readableCopy;
});

final configStateStoreProvider = Provider<ConfigStateStore>((ref) {
  return ref.watch(dashboardStateProvider).config;
});

final telemetryMetricsStoreProvider = Provider<TelemetryMetricsStore>((ref) {
  return ref.watch(dashboardStateProvider).metrics;
});

final gpsStateStoreProvider = Provider<GpsStateStore>((ref) {
  return ref.watch(dashboardStateProvider).gps;
});

final canIngestRepositoryProvider = Provider<CanIngestRepository>((ref) {
  final repository = IsolateCanIngestRepository();
  ref.onDispose(() {
    unawaited(repository.dispose());
  });
  return repository;
});

final useLightThemeProvider = Provider<bool>((ref) {
  return ref.watch(dashboardStateProvider.select((s) => s.useLightTheme));
});

typedef DashboardNavState = ({bool isLogging, UiMode uiMode});

final dashboardNavStateProvider = Provider<DashboardNavState>((ref) {
  return ref.watch(
    dashboardStateProvider.select(
      (s) => (isLogging: s.isLogging, uiMode: s.uiMode),
    ),
  );
});
