import 'package:telemetry_dashboard/ui/widgets/driver/efficiency_grid.dart';
import 'package:telemetry_dashboard/ui/widgets/service/config_view.dart';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/tx_can_command.dart';
import 'package:telemetry_dashboard/providers/app_providers.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';

import 'package:telemetry_dashboard/core/theme/palette.dart';

// =============================================================================
// ROOT SCREEN: PageView with Driver + Config pages
// =============================================================================
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final PageController _pageController = PageController();
  int _selectedPage = 0;

  Timer? _blinkTimer;
  bool _blinkOn = true;

  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() => _blinkOn = !_blinkOn);
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _showInfoSnackbar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setPage({
    required DashboardState state,
    required int pageIndex,
    bool announceBlocked = true,
  }) async {
    if (pageIndex != 0 && state.isLogging) {
      if (announceBlocked) {
        _showInfoSnackbar('Service pages are locked while logging.');
      }
      return;
    }

    final nextMode = pageIndex == 0 ? UiMode.driver : UiMode.service;
    if (state.uiMode != nextMode) {
      state.setUiMode(nextMode);
    }

    if (_selectedPage != pageIndex) {
      setState(() {
        _selectedPage = pageIndex;
      });
    }

    if (_pageController.hasClients) {
      await _pageController.animateToPage(
        pageIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _handleServicePageTap({
    required DashboardState state,
    required int pageIndex,
  }) async {
    if (state.isLogging) {
      _showInfoSnackbar('Service pages are locked while logging.');
      return;
    }

    if (state.uiMode != UiMode.service) {
      _showInfoSnackbar('Long-press CFG to enter Service mode.');
      return;
    }

    await _setPage(state: state, pageIndex: pageIndex, announceBlocked: false);
  }

  Future<void> _handleServicePageLongPress({
    required DashboardState state,
    required int pageIndex,
  }) async {
    if (state.isLogging) {
      _showInfoSnackbar('Service pages are locked while logging.');
      return;
    }

    await _setPage(state: state, pageIndex: pageIndex, announceBlocked: false);
  }

  Future<void> _dispatchAuxCommand({
    required BuildContext context,
    required DashboardState state,
    required String commandKey,
    required String legacyRawCommand,
    List<int> args = const <int>[],
  }) async {
    final messenger = ScaffoldMessenger.of(context);

    if (!state.useDictionaryAuxDispatch) {
      state.sendUsbCommand(legacyRawCommand);
      return;
    }

    final result = await state.sendDictionaryCommand(
      TxCanCommand(
        commandKey: commandKey,
        args: args,
        targetCanId: null,
        issuedAtMsUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
        source: 'driver_ui',
        safetyTag: CanTxSafetyClass.operational,
      ),
    );

    if (!mounted) {
      return;
    }

    final shouldFallbackToLegacy =
        result.status.name == 'rejected' &&
        (result.reason == 'tx_service_unavailable' ||
            result.reason == 'unknown_command_key' ||
            result.reason == 'target_can_mismatch');

    if (shouldFallbackToLegacy) {
      state.sendUsbCommand(legacyRawCommand);
      return;
    }

    if (result.status.name == 'acked') {
      return;
    }

    final reason = result.reason == null ? '' : ' (${result.reason})';
    final label = result.command.commandKey;
    final status = result.status.name.toUpperCase();
    messenger.showSnackBar(SnackBar(content: Text('$label $status$reason')));
  }

  void _handleAbortSession(BuildContext context, DashboardState state) {
    if (state.isLogging) {
      final stopped = state.stopSession(abort: true);
      if (stopped) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session aborted forcefully.')),
        );
      }
    }
  }

  void _handleStartStop(BuildContext context, DashboardState state) {
    final p = Palette(state.useLightTheme);
    final messenger = ScaffoldMessenger.of(context);
    if (state.isLogging) {
      final stopped = state.stopSession();
      if (!stopped) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              state.endBlockReason ??
                  'Stop blocked until the CAN interface is ready. Hold to force-stop instead.',
            ),
          ),
        );
      }
    } else {
      final nameController = TextEditingController(
        text: state.generateDefaultName(),
      );
      // Create a controller for the host address
      final hostController = TextEditingController(text: state.mqttHost);

      showDialog(
        context: context,
        barrierDismissible: false, // Force a decision
        builder: (context) => AlertDialog(
          scrollable: true,
          backgroundColor: const Color(0xFF121212),
          title: Row(
            children: [
              Icon(Icons.cell_tower, color: p.cyan, size: 20),
              const SizedBox(width: 10),
              const Text(
                "SESSION CONFIG",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // RUN NAME INPUT
              TextField(
                controller: nameController,
                autofocus: true,
                style: TextStyle(
                  color: p.cyan,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  labelText: "RUN NAME",
                  labelStyle: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 1.2,
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: p.border),
                  ),
                ),
              ),
              const SizedBox(height: 20),

                // MQTT DESTINATION INPUT (The Safeguard)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "TARGET DESTINATION (MQTT HOST)",
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextField(
                        controller: hostController,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: "e.g. 100.x.x.x or pitwall-laptop",
                          hintStyle: TextStyle(color: Colors.white10),
                          border: InputBorder.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "CANCEL",
                style: TextStyle(color: Colors.white30),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.green.withValues(alpha: 0.8),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              onPressed: () {
                // 1. Update the host in state first
                state.updateMqttHost(hostController.text);
                // 2. Start the session with the provided name
                final started = state.startSession(
                  nameController.text,
                );
                if (started) {
                  Navigator.pop(context);
                } else {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        state.startBlockReason ??
                            'Start blocked until standstill requirements are met.',
                      ),
                    ),
                  );
                }
              },
              child: const Text(
                "CONFIRM & START",
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final useLightTheme = ref.watch(useLightThemeProvider);
    final navState = ref.watch(dashboardNavStateProvider);
    final p = Palette(useLightTheme);

    if (navState.isLogging && _selectedPage != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(
          _setPage(
            state: ref.read(dashboardStateProvider),
            pageIndex: 0,
            announceBlocked: false,
          ),
        );
      });
    }

    return Scaffold(
      backgroundColor: p.bg,
      body: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Column(
          children: [
            Consumer(
              builder: (context, ref, _) {
                final state = ref.watch(dashboardStateProvider);
                return _buildCompactStatusBar(state, p);
              },
            ),
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                  },
                ),
                child: PageView(
                  controller: _pageController,
                  physics:
                      navState.uiMode == UiMode.service && !navState.isLogging
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  onPageChanged: (index) {
                    if (_selectedPage != index) {
                      setState(() {
                        _selectedPage = index;
                      });
                    }

                    final state = ref.read(dashboardStateProvider);
                    if (state.isLogging) {
                      return;
                    }
                    final nextMode = index == 0
                        ? UiMode.driver
                        : UiMode.service;
                    if (state.uiMode != nextMode) {
                      state.setUiMode(nextMode);
                    }
                  },
                  children: [
                    Consumer(
                      builder: (context, ref, _) {
                        final state = ref.watch(dashboardStateProvider);
                        return EfficiencyGrid(state: state, p: p);
                      },
                    ),
                    ConfigView(p: p),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactStatusBar(DashboardState state, Palette p) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final widthScale = (width / 1600.0).clamp(0.78, 1.0).toDouble();
        final isCompact = width < 1280;
        final isTight = width < 980;
        final isVeryTight = width < 760;

        final indicatorWidth = (48.0 * widthScale)
            .clamp(isVeryTight ? 34.0 : 38.0, 48.0)
            .toDouble();
        final indicatorIconSize = (24.0 * widthScale)
            .clamp(isVeryTight ? 16.0 : 18.0, 24.0)
            .toDouble();
        final navButtonWidth = (40.0 * widthScale)
            .clamp(isVeryTight ? 30.0 : 34.0, 40.0)
            .toDouble();
        final navButtonHeight = (22.0 * widthScale)
            .clamp(isVeryTight ? 16.0 : 18.0, 22.0)
            .toDouble();
        final navButtonFontSize = (10.0 * widthScale)
            .clamp(isVeryTight ? 8.0 : 9.0, 10.0)
            .toDouble();
        final statusFontSize = (12.0 * widthScale)
            .clamp(isVeryTight ? 8.5 : 9.5, 12.0)
            .toDouble();
        final detailFontSize = (11.0 * widthScale)
            .clamp(isVeryTight ? 8.0 : 9.0, 11.0)
            .toDouble();
        final topBarHeight = (40.0 * widthScale)
            .clamp(isVeryTight ? 32.0 : 34.0, 40.0)
            .toDouble();
        final onlineLabel = isCompact
            ? (state.isServerConnected ? 'ON' : 'OFF')
            : (state.isServerConnected ? 'ONLINE' : 'OFFLINE');
        final sourceColor = state.isSimulated
            ? p.amber
            : (state.isConnected ? p.green : p.red);
        final sourceIcon = state.isSimulated
            ? Icons.memory
            : (state.isConnected ? Icons.usb_rounded : Icons.usb_off_rounded);
        final sourceLabel = state.isSimulated
            ? 'SIM'
            : (state.isConnected ? 'USB' : 'OFF');
        final sourceText = isCompact ? sourceLabel : 'SRC:$sourceLabel';
        final gpsSourceIcon = state.usingPhoneGpsFallback
            ? Icons.phone_android_rounded
            : state.gpsLocked
            ? Icons.satellite_alt_rounded
            : Icons.gps_off_rounded;
        final gpsSourceColor = state.gpsLocked
            ? (state.usingPhoneGpsFallback ? p.amber : p.cyan)
            : p.red;
        final gpsStatusLabel = state.gpsLocked ? 'FIX' : 'NO FIX';

        final isServerOffline = !state.isServerConnected;

        return Container(
          height: topBarHeight,
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: isServerOffline
                ? p.orange.withValues(alpha: 0.14)
                : p.bg,
            border: Border.all(
              color: isServerOffline ? p.orange : p.border,
              width: isServerOffline ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Row(
                children: [
                  _buildIndicator(
                    Icons.keyboard_arrow_left,
                    state.leftTurn && _blinkOn,
                    p.green,
                    p,
                    width: indicatorWidth,
                    iconSize: indicatorIconSize,
                    onTap: () {
                      unawaited(
                        _dispatchAuxCommand(
                          context: context,
                          state: state,
                          commandKey: 'LEFT_TURN_TOGGLE',
                          legacyRawCommand: 'CMD:LEFT_TURN\n',
                        ),
                      );
                    },
                  ),
                  _buildIndicator(
                    Icons.lightbulb,
                    state.headlights,
                    Colors.blueAccent,
                    p,
                    width: indicatorWidth,
                    iconSize: indicatorIconSize,
                    onTap: () {
                      unawaited(
                        _dispatchAuxCommand(
                          context: context,
                          state: state,
                          commandKey: 'HEADLIGHTS_TOGGLE',
                          legacyRawCommand: 'CMD:HEADLIGHTS\n',
                        ),
                      );
                    },
                  ),
                  _buildIndicator(
                    Icons.local_car_wash,
                    state.wipers,
                    p.cyan,
                    p,
                    width: indicatorWidth,
                    iconSize: indicatorIconSize,
                    onTap: () {
                      unawaited(
                        _dispatchAuxCommand(
                          context: context,
                          state: state,
                          commandKey: 'WIPERS_TOGGLE',
                          legacyRawCommand: 'CMD:WIPERS\n',
                        ),
                      );
                    },
                  ),
                  _buildIndicator(
                    Icons.volume_up,
                    state.horn,
                    p.orange,
                    p,
                    width: indicatorWidth,
                    iconSize: indicatorIconSize,
                    onTap: () {
                      unawaited(
                        _dispatchAuxCommand(
                          context: context,
                          state: state,
                          commandKey: 'HORN_PULSE_MS',
                          args: const <int>[250],
                          legacyRawCommand: 'CMD:HORN\n',
                        ),
                      );
                    },
                  ),
                  _buildIndicator(
                    Icons.warning,
                    state.hazards && _blinkOn,
                    p.red,
                    p,
                    width: indicatorWidth,
                    iconSize: indicatorIconSize,
                    onTap: () {
                      unawaited(
                        _dispatchAuxCommand(
                          context: context,
                          state: state,
                          commandKey: 'HAZARDS_TOGGLE',
                          legacyRawCommand: 'CMD:HAZARDS\n',
                        ),
                      );
                    },
                  ),
                  _buildIndicator(
                    Icons.keyboard_arrow_right,
                    state.rightTurn && _blinkOn,
                    p.green,
                    p,
                    width: indicatorWidth,
                    iconSize: indicatorIconSize,
                    onTap: () {
                      unawaited(
                        _dispatchAuxCommand(
                          context: context,
                          state: state,
                          commandKey: 'RIGHT_TURN_TOGGLE',
                          legacyRawCommand: 'CMD:RIGHT_TURN\n',
                        ),
                      );
                    },
                  ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: isTight ? 6.0 : 10.0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Tooltip(
                            message:
                                '${state.gpsSourceText} | ${state.gpsStatusText}',
                            child: Icon(
                              gpsSourceIcon,
                              color: gpsSourceColor,
                              size: (14.0 * widthScale).clamp(11.0, 14.0),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            gpsStatusLabel,
                            style: TextStyle(
                              color: gpsSourceColor,
                              fontSize: statusFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (!state.gpsPermissionsHealthy && !isCompact) ...[
                            const SizedBox(width: 6),
                            Text(
                              state.gpsPermissionStatusText,
                              style: TextStyle(
                                color: p.red,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(width: 10),
                          Text(
                            'LAP ${state.lapProgressText}',
                            style: TextStyle(
                              color: p.lightGreen,
                              fontSize: statusFontSize,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          if (!isCompact) ...[
                            const SizedBox(width: 8),
                            Text(
                              state.crossingStatusText,
                              style: TextStyle(
                                color: state.deadzoneActive ? p.orange : p.cyan,
                                fontSize: detailFontSize,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (state.deadzoneActive) ...[
                              const SizedBox(width: 6),
                              Text(
                                'DZ ${state.deadzoneText}',
                                style: TextStyle(
                                  color: p.orange,
                                  fontSize: detailFontSize,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(width: 12),
                          Icon(
                            Icons.warning_amber_rounded,
                            color: state.errorCount > 0 ? p.red : p.border,
                            size: isTight ? 12 : 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'ERR:${state.errorCount}',
                            style: TextStyle(
                              color: state.errorCount > 0 ? p.red : p.dimText,
                              fontSize: statusFontSize,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(width: isCompact ? 6 : 10),
                          Icon(sourceIcon, color: sourceColor, size: 10),
                          const SizedBox(width: 4),
                          Text(
                            sourceText,
                            style: TextStyle(
                              color: sourceColor,
                              fontSize: statusFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            onlineLabel,
                            style: TextStyle(
                              color: state.isServerConnected ? p.cyan : p.red,
                              fontSize: statusFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Q:${state.unsentBatchCount}',
                            style: TextStyle(
                              color: state.spoolCapacityWarning
                                  ? p.red
                                  : (state.unsentBatchCount > 0
                                        ? p.orange
                                        : p.lightGreen),
                              fontSize: detailFontSize,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          if (state.spoolCapacityWarning && !isTight) ...[
                            const SizedBox(width: 6),
                            Text(
                              'SPOOL ${state.spoolUsageText}',
                              style: TextStyle(
                                color: p.red,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                          _buildModeNavButton(
                            label: 'DRV',
                            active: _selectedPage == 0,
                            activeColor: p.cyan,
                            p: p,
                            width: navButtonWidth,
                            height: navButtonHeight,
                            fontSize: navButtonFontSize,
                            onTap: () {
                              unawaited(_setPage(state: state, pageIndex: 0));
                            },
                          ),
                          const SizedBox(width: 4),
                          _buildModeNavButton(
                            label: 'CFG',
                            active: _selectedPage == 1,
                            activeColor: p.lightGreen,
                            p: p,
                            width: navButtonWidth,
                            height: navButtonHeight,
                            fontSize: navButtonFontSize,
                            onTap: () {
                              unawaited(
                                _handleServicePageTap(
                                  state: state,
                                  pageIndex: 1,
                                ),
                              );
                            },
                            onLongPress: () {
                              unawaited(
                                _handleServicePageLongPress(
                                  state: state,
                                  pageIndex: 1,
                                ),
                              );
                            },
                          ),
                          // Vertical separator — safe zone boundary
                          const SizedBox(width: 10),
                          Container(width: 1, height: topBarHeight * 0.6, color: p.border),
                          const SizedBox(width: 10),
                          // START/STOP anchored to far right
                          GestureDetector(
                            // STOP = tap (urgent), ABORT = long-press (force), START = long-press (deliberate)
                            onTap: state.isLogging
                                ? () => _handleStartStop(context, state)
                                : null,
                            onLongPress: state.isLogging
                                ? () => _handleAbortSession(context, state)
                                : () => _handleStartStop(context, state),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: EdgeInsets.symmetric(
                                horizontal: isTight ? 14 : 20,
                                vertical: isTight ? 4 : 6,
                              ),
                              decoration: BoxDecoration(
                                color: state.isLogging
                                    ? p.red.withValues(alpha: 0.2)
                                    : p.green.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: state.isLogging ? p.red : p.green,
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  if (state.isLogging)
                                    BoxShadow(
                                      color: p.red.withValues(alpha: 0.4),
                                      blurRadius: 8,
                                      spreadRadius: 1,
                                    ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    state.isLogging
                                        ? Icons.stop
                                        : Icons.play_arrow,
                                    color: state.isLogging ? p.red : p.green,
                                    size: isTight ? 14 : 16,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    state.isLogging ? 'STOP' : 'HOLD',
                                    style: TextStyle(
                                      color: state.isLogging ? p.red : p.green,
                                      fontSize: isTight ? 11 : 12,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.1,
                                    ),
                                  ),
                                  if (state.isLogging &&
                                      state.unsentBatchCount > 0) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: p.orange.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: p.orange,
                                          width: 1,
                                        ),
                                      ),
                                      child: Text(
                                        '${state.unsentBatchCount}',
                                        style: TextStyle(
                                          color: p.orange,
                                          fontSize: isTight ? 10 : 11,
                                          fontWeight: FontWeight.w900,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildIndicator(
    IconData icon,
    bool active,
    Color color,
    Palette p, {
    VoidCallback? onTap,
    double width = 48,
    double iconSize = 24,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: width,
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          border: Border(right: BorderSide(color: p.border, width: 1)),
        ),
        child: Icon(
          icon,
          color: active ? (p.light ? Colors.white : Colors.black) : p.border,
          size: iconSize,
        ),
      ),
    );
  }

  Widget _buildModeNavButton({
    required String label,
    required bool active,
    required Color activeColor,
    required Palette p,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    double width = 40,
    double height = 22,
    double fontSize = 10,
  }) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? activeColor.withValues(alpha: 0.25)
              : Colors.transparent,
          border: Border.all(color: active ? activeColor : p.border, width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? activeColor : p.dimText,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}


