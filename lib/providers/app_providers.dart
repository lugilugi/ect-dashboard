import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:telemetry_dashboard/repositories/can_ingest_repository.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

final dashboardStateProvider = ChangeNotifierProvider<DashboardState>((ref) {
  final state = DashboardState();
  ref.onDispose(state.dispose);
  return state;
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
