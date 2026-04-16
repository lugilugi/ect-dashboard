import 'dart:async';
import 'dart:ui';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../models/can_messages.dart';
import '../models/session_models.dart';
import '../models/tx_can_command.dart';
import '../providers/dashboard_state.dart';
import '../services/lap_boundary_service.dart';

// =============================================================================
// Helper: theme-aware color palette
// =============================================================================
class _Palette {
  final bool light;
  _Palette(this.light);

  Color get bg => light ? const Color(0xFFF5F5F5) : Colors.black;
  Color get panel => light ? Colors.white : Colors.transparent;
  Color get border => light ? Colors.black26 : Colors.white24;
  Color get dimText => light ? Colors.black54 : Colors.white54;
  Color get mainText => light ? Colors.black : Colors.white;
  Color get barBg => light ? Colors.grey.shade300 : Colors.transparent;

  // High-contrast accent overrides for light theme
  Color get cyan => light ? const Color(0xFF006064) : Colors.cyanAccent;
  Color get green => light ? const Color(0xFF1B5E20) : Colors.greenAccent;
  Color get amber => light ? const Color(0xFF8F6E00) : Colors.amberAccent;
  Color get orange => light ? const Color(0xFFBF360C) : Colors.orangeAccent;
  Color get red => light ? const Color(0xFFB71C1C) : Colors.redAccent;
  Color get yellow => light ? const Color(0xFF827717) : Colors.yellowAccent;
  Color get purple => light ? const Color(0xFF4A148C) : Colors.purpleAccent;
  Color get teal => light ? const Color(0xFF004D40) : Colors.tealAccent;
  Color get pink => light ? const Color(0xFF880E4F) : Colors.pinkAccent;
  Color get lightGreen =>
      light ? const Color(0xFF33691E) : Colors.lightGreenAccent;
  Color get deepOrange =>
      light ? const Color(0xFFBF360C) : Colors.deepOrangeAccent;
}

// =============================================================================
// ROOT SCREEN: PageView with Driver + Config pages
// =============================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final PageController _pageController = PageController();
  int _selectedPage = 0;

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

    if (state.isLogging && state.uiMode == UiMode.driver) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Aux commands are locked in Driver mode while logging.',
          ),
        ),
      );
      return;
    }

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

  void _handleStartStop(BuildContext context, DashboardState state) {
    final p = _Palette(state.useLightTheme);
    final messenger = ScaffoldMessenger.of(context);
    if (state.isLogging) {
      final stopped = state.stopSession();
      if (!stopped) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              state.endBlockReason ??
                  'Stop blocked until lap target is reached or abort is used.',
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
      final plannedLapsController = TextEditingController(
        text: state.lapsPlanned.toString(),
      );

      showDialog(
        context: context,
        barrierDismissible: false, // Force a decision
        builder: (context) => AlertDialog(
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
              const SizedBox(height: 14),
              TextField(
                controller: plannedLapsController,
                keyboardType: TextInputType.number,
                style: TextStyle(
                  color: p.lightGreen,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  labelText: 'PLANNED LAPS',
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
                final parsedLaps = int.tryParse(
                  plannedLapsController.text.trim(),
                );
                final plannedLaps = parsedLaps ?? state.lapsPlanned;
                state.setLapsPlanned(plannedLaps);
                // 2. Start the session with the provided name
                final started = state.startSession(
                  nameController.text,
                  plannedLaps: plannedLaps,
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
    final state = context.watch<DashboardState>();
    final p = _Palette(state.useLightTheme);

    if (state.isLogging && _selectedPage != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_setPage(state: state, pageIndex: 0, announceBlocked: false));
      });
    }

    return Scaffold(
      backgroundColor: p.bg,
      body: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Column(
          children: [
            _buildCompactStatusBar(state, p),
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
                  physics: state.uiMode == UiMode.service && !state.isLogging
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  onPageChanged: (index) {
                    if (_selectedPage != index) {
                      setState(() {
                        _selectedPage = index;
                      });
                    }
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
                    _EfficiencyGrid(state: state, p: p),
                    _ConfigView(state: state, p: p),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactStatusBar(DashboardState state, _Palette p) {
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
        final gpsSourceIcon = !state.gpsLocked
            ? Icons.gps_off_rounded
            : state.usingPhoneGpsFallback
            ? Icons.phone_android_rounded
            : Icons.satellite_alt_rounded;
        final gpsSourceColor = !state.gpsLocked
            ? p.red
            : state.usingPhoneGpsFallback
            ? p.amber
            : p.cyan;
        final gpsStatusLabel = isVeryTight
            ? state.gpsLocked
                  ? (state.usingPhoneGpsFallback ? 'PHONE FIX' : '3D FIX')
                  : 'NO FIX'
            : state.gpsStatusText;

        return Container(
          height: topBarHeight,
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: p.bg,
            border: Border.all(color: p.border, width: 1),
          ),
          child: Row(
            children: [
              Row(
                children: [
                  _buildIndicator(
                    Icons.keyboard_arrow_left,
                    state.leftTurn,
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
                    state.hazards,
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
                    state.rightTurn,
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
                            message: state.gpsSourceText,
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
                          GestureDetector(
                            onTap: () => _handleStartStop(context, state),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: EdgeInsets.symmetric(
                                horizontal: isTight ? 8 : 12,
                                vertical: isTight ? 3 : 4,
                              ),
                              decoration: BoxDecoration(
                                color: state.isLogging
                                    ? p.red.withValues(alpha: 0.2)
                                    : p.green.withValues(alpha: 0.1),
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
                                    state.isLogging ? 'STOP' : 'START',
                                    style: TextStyle(
                                      color: state.isLogging ? p.red : p.green,
                                      fontSize: isTight ? 11 : 12,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (!isTight) ...[
                            Text(
                              'LOCAL',
                              style: TextStyle(
                                color: p.dimText,
                                fontSize: statusFontSize,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 10),
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
                          if (!isCompact && !isVeryTight) ...[
                            const SizedBox(width: 12),
                            Text(
                              state.systemTimeString,
                              style: TextStyle(
                                color: p.amber,
                                fontFamily: 'monospace',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                fontSize: (14.0 * widthScale).clamp(10.0, 14.0),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                          SizedBox(width: isCompact ? 12 : 18),
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
                          Icon(
                            Icons.sensors,
                            color: state.isServerConnected ? p.cyan : p.red,
                            size: 10,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            onlineLabel,
                            style: TextStyle(
                              color: state.isServerConnected ? p.cyan : p.red,
                              fontSize: statusFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 10),
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
                          if (state.unsentBatchCount > 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              isTight
                                  ? 'A:${state.oldestUnsentAgeText}'
                                  : 'AGE:${state.oldestUnsentAgeText}',
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
    _Palette p, {
    VoidCallback? onTap,
    double width = 48,
    double iconSize = 24,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: width,
        height: double.infinity,
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
    required _Palette p,
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

// =============================================================================
// PAGE 1: EFFICIENCY GRID (Driver View)
// =============================================================================
class _EfficiencyGrid extends StatelessWidget {
  final DashboardState state;
  final _Palette p;
  const _EfficiencyGrid({required this.state, required this.p});

  @override
  Widget build(BuildContext context) {
    double powerW = state.mainVoltage * state.current780;
    Color powerColor = p.mainText;
    if (powerW < 0) {
      powerColor = p.cyan;
    } else if (powerW > 3000) {
      powerColor = Colors.red;
    } else if (powerW > 2000) {
      powerColor = p.red;
    } else if (powerW > 1000) {
      powerColor = p.orange;
    }

    return Container(
      decoration: BoxDecoration(border: Border.all(color: p.border, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // LEFT COL: Voltage, Power, Temps
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: _buildSplitCell(
                          "VOLTAGE / CURRENT",
                          state.mainVoltage.toStringAsFixed(1),
                          "V",
                          state.current780.toStringAsFixed(1),
                          "A",
                          bottomBorder: true,
                          rightBorder: true,
                          color1: p.yellow,
                          color2: p.cyan,
                        ),
                      ),
                      Expanded(
                        child: _buildGridCell(
                          "POWER",
                          powerW.toStringAsFixed(0),
                          "W",
                          bottomBorder: true,
                          rightBorder: true,
                          valueColor: powerColor,
                        ),
                      ),
                      Expanded(
                        child: _buildSplitCell(
                          "M.C. TEMP / BATT TEMP",
                          state.mcTempC.toStringAsFixed(0),
                          "°C",
                          state.battTempC.toStringAsFixed(0),
                          "°C",
                          bottomBorder: false,
                          rightBorder: true,
                          color1: state.mcTempC > 80 ? p.red : p.orange,
                          color2: state.battTempC > 50 ? p.red : p.deepOrange,
                        ),
                      ),
                    ],
                  ),
                ),

                // CENTER COL: Throttle → Speed Bar → Efficiency+Session
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      _buildGridThrottleBar(),
                      Expanded(
                        flex: 5,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: p.border, width: 1),
                            ),
                          ),
                          child: _buildSpeedBarGraph(),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: _buildBottomCenterMetrics(state),
                      ),
                    ],
                  ),
                ),

                // RIGHT COL: Avg Eff → Fault+Strategy → Rolling Graph
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: _buildSplitCell(
                          "AVG EFF. / ENERGY",
                          state.avgKmPerKwh.toStringAsFixed(2),
                          "km/kWh",
                          (state.energyJ780 / 3600.0).toStringAsFixed(1),
                          "Wh",
                          leftBorder: true,
                          bottomBorder: true,
                          color1: p.lightGreen,
                          color2: p.purple,
                        ),
                      ),
                      Expanded(child: _buildFaultStrategyCell()),
                      Expanded(child: _buildRollingGraph()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Speed Bar Graph (center hero)
  // ---------------------------------------------------------------------------
  Widget _buildSpeedBarGraph() {
    final fraction =
        (state.speedKmh / max(state.speedUpperThreshold * 1.5, 1.0)).clamp(
          0.0,
          1.0,
        );
    final upperFrac =
        (state.speedUpperThreshold / (state.speedUpperThreshold * 1.5)).clamp(
          0.0,
          1.0,
        );
    final lowerFrac =
        (state.speedLowerThreshold / (state.speedUpperThreshold * 1.5)).clamp(
          0.0,
          1.0,
        );

    Color barColor;
    if (state.speedKmh >= state.speedUpperThreshold) {
      barColor = p.orange;
    } else if (state.speedKmh <= state.speedLowerThreshold) {
      barColor = p.cyan;
    } else {
      barColor = p.green;
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: barColor,
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              "SPEED",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.light ? Colors.white : Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final barHeight = constraints.maxHeight;
              return Stack(
                children: [
                  // Background
                  Container(color: p.barBg),
                  // Fill bar (from bottom)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: barHeight * fraction,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor.withValues(alpha: 0.4),
                        border: Border(
                          top: BorderSide(color: barColor, width: 3),
                        ),
                      ),
                    ),
                  ),
                  // Upper threshold line (BURN → COAST)
                  Positioned(
                    bottom: barHeight * upperFrac,
                    left: 0,
                    right: 0,
                    child: Container(height: 2, color: p.orange, child: null),
                  ),
                  Positioned(
                    bottom: barHeight * upperFrac + 4,
                    right: 8,
                    child: Text(
                      "▲ COAST ${state.speedUpperThreshold.toInt()} km/h",
                      style: TextStyle(
                        color: p.orange,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Lower threshold line (COAST → BURN)
                  Positioned(
                    bottom: barHeight * lowerFrac,
                    left: 0,
                    right: 0,
                    child: Container(height: 2, color: p.cyan),
                  ),
                  Positioned(
                    bottom: barHeight * lowerFrac + 4,
                    right: 8,
                    child: Text(
                      "▼ BURN ${state.speedLowerThreshold.toInt()} km/h",
                      style: TextStyle(
                        color: p.cyan,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Digital speed overlay (center)
                  Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            state.speedKmh.toStringAsFixed(1),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: p.mainText,
                              fontSize: 80,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                          ),
                          Text(
                            "km/h",
                            style: TextStyle(
                              color: p.dimText,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Combined Fault + Strategy Cell (right col, middle)
  // ---------------------------------------------------------------------------
  Widget _buildFaultStrategyCell() {
    final hasFault = state.lastErrorCode != "OK";
    Color strategyColor = p.mainText;
    if (state.strategy == "BURN") {
      strategyColor = p.orange;
    }
    if (state.strategy == "REGEN") {
      strategyColor = p.red;
    }
    if (state.strategy == "COAST") {
      strategyColor = p.cyan;
    }
    if (state.strategy == "PACE") {
      strategyColor = p.green;
    }

    return Container(
      decoration: BoxDecoration(
        color: hasFault
            ? Colors.red.shade900.withValues(alpha: 0.8)
            : Colors.transparent,
        border: Border(
          left: BorderSide(color: p.border, width: 1),
          bottom: BorderSide(color: p.border, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Fault area (top half)
          Expanded(
            flex: 1,
            child: hasFault
                ? Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.error,
                              color: Colors.red,
                              size: 24,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              state.lastErrorCode,
                              style: const TextStyle(
                                color: Colors.red,
                                fontFamily: 'monospace',
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Icon(
                      Icons.check_circle_outline,
                      color: p.border,
                      size: 20,
                    ),
                  ),
          ),
          Container(height: 1, color: p.border),
          // Strategy area (bottom half)
          Expanded(
            flex: 1,
            child: Container(
              color: strategyColor.withValues(alpha: p.light ? 0.2 : 0.15),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(
                      state.strategy,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: strategyColor,
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Rolling Graph (right col, bottom)
  // ---------------------------------------------------------------------------
  Widget _buildRollingGraph() {
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4, right: 8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                "${state.graphMetric.toUpperCase()} HISTORY",
                style: TextStyle(
                  color: p.dimText,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: CustomPaint(
                painter: _GraphPainter(state.graphHistory.toList(), p),
                size: Size.infinite,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Throttle Bar
  // ---------------------------------------------------------------------------
  Widget _buildGridThrottleBar() {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: state.isBrakePressed ? p.red : Colors.transparent,
            ),
            alignment: Alignment.center,
            child: Text(
              state.isBrakePressed ? "BRK " : "THR ",
              style: TextStyle(
                color: state.isBrakePressed
                    ? (p.light ? Colors.white : Colors.black)
                    : p.dimText,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          Container(width: 1, color: p.border),
          Expanded(
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                FractionallySizedBox(
                  widthFactor: (state.throttlePercent / 100).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: state.throttlePercent > 85 ? p.orange : p.green,
                      boxShadow: [
                        BoxShadow(
                          color:
                              (state.throttlePercent > 85 ? p.orange : p.green)
                                  .withValues(alpha: 0.6),
                          blurRadius: 15,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: p.border),
          Container(
            width: 80,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              "${state.throttlePercent.toStringAsFixed(0)}%",
              style: TextStyle(
                fontFamily: 'monospace',
                fontFeatures: const [FontFeature.tabularFigures()],
                color: p.orange,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Split Cell (two values side by side)
  // ---------------------------------------------------------------------------
  Widget _buildSplitCell(
    String mainTitle,
    String val1,
    String unit1,
    String val2,
    String unit2, {
    bool leftBorder = false,
    bool rightBorder = false,
    bool topBorder = false,
    bool bottomBorder = false,
    Color color1 = Colors.white,
    Color color2 = Colors.white,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          left: leftBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
          right: rightBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
          top: topBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
          bottom: bottomBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 6, right: 8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                mainTitle,
                style: TextStyle(
                  color: p.dimText,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              val1,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: color1,
                                fontSize: 42,
                                fontWeight: FontWeight.bold,
                                height: 1.0,
                              ),
                            ),
                            if (unit1.isNotEmpty)
                              Text(
                                unit1,
                                style: TextStyle(
                                  color: p.dimText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Container(width: 1, color: p.border, height: 40),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              val2,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: color2,
                                fontSize: 42,
                                fontWeight: FontWeight.bold,
                                height: 1.0,
                              ),
                            ),
                            if (unit2.isNotEmpty)
                              Text(
                                unit2,
                                style: TextStyle(
                                  color: p.dimText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridCell(
    String title,
    String value,
    String unit, {
    bool leftBorder = false,
    bool rightBorder = false,
    bool topBorder = false,
    bool bottomBorder = false,
    Color valueColor = Colors.white,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          left: leftBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
          right: rightBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
          top: topBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
          bottom: bottomBorder
              ? BorderSide(color: p.border, width: 1)
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 6, right: 8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: TextStyle(
                  color: p.dimText,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      value,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: valueColor,
                        fontSize: 56,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                    if (unit.isNotEmpty)
                      Text(
                        unit,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: p.dimText,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom Center: Efficiency + Session/Lap/Dist
  // ---------------------------------------------------------------------------
  Widget _buildBottomCenterMetrics(DashboardState state) {
    Color instEffColor = state.strategy == "REGEN" ? p.cyan : p.mainText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LEFT HALF: INSTANT EFFICIENCY (swapped from speed)
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 6, right: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "INSTANT km/kWh",
                    style: TextStyle(
                      color: p.dimText,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        state.instKmPerKwh > 90.0
                            ? "MAX"
                            : state.instKmPerKwh.toStringAsFixed(2),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: instEffColor,
                          fontSize: 62,
                          fontWeight: FontWeight.bold,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "km/kWh",
                        style: TextStyle(
                          color: p.dimText,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(width: 1, color: p.border),
        // RIGHT HALF: SESS, LAP, DIST
        Expanded(
          flex: 3,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: p.border, width: 1),
                    ),
                  ),
                  child: _buildMiniRow(
                    "SESS",
                    state.sessionTimeString,
                    valColor: p.amber,
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: p.border, width: 1),
                    ),
                  ),
                  child: _buildMiniRow(
                    "LAP",
                    state.lapNumber.toString(),
                    valColor: p.pink,
                  ),
                ),
              ),
              Expanded(
                child: _buildMiniRow(
                  "DIST",
                  "${state.distanceKm.toStringAsFixed(2)} km",
                  valColor: p.teal,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMiniRow(
    String label,
    String val, {
    Color valColor = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.dimText,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            val,
            style: TextStyle(
              fontFamily: 'monospace',
              fontFeatures: const [FontFeature.tabularFigures()],
              color: valColor,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Rolling Graph Custom Painter
// =============================================================================
class _GraphPainter extends CustomPainter {
  final List<double> data;
  final _Palette p;
  _GraphPainter(this.data, this.p);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final maxVal = data.reduce(max);
    final minVal = data.reduce(min);
    final range = maxVal - minVal;
    if (range <= 0) return;

    final paint = Paint()
      ..color = p.cyan
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - minVal) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => true;
}

class _ThrottleMapPainter extends CustomPainter {
  final _Palette p;
  final List<double> values;

  _ThrottleMapPainter({required this.p, required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 5) {
      return;
    }

    const pad = 18.0;
    final chartRect = Rect.fromLTWH(
      pad,
      pad,
      max(1.0, size.width - (pad * 2)),
      max(1.0, size.height - (pad * 2)),
    );

    final gridPaint = Paint()
      ..color = p.border
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = p.dimText
      ..strokeWidth = 1.4;

    for (int i = 0; i <= 4; i++) {
      final tx = chartRect.left + chartRect.width * (i / 4);
      final ty = chartRect.top + chartRect.height * (i / 4);
      canvas.drawLine(
        Offset(tx, chartRect.top),
        Offset(tx, chartRect.bottom),
        i == 0 ? axisPaint : gridPaint,
      );
      canvas.drawLine(
        Offset(chartRect.left, ty),
        Offset(chartRect.right, ty),
        i == 4 ? axisPaint : gridPaint,
      );
    }

    final linePaint = Paint()
      ..color = p.orange
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final fillPointPaint = Paint()
      ..color = p.orange
      ..style = PaintingStyle.fill;
    final pointOutlinePaint = Paint()
      ..color = p.bg
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final dx = chartRect.left + chartRect.width * (i / (values.length - 1));
      final dy = chartRect.bottom - chartRect.height * (values[i] / 100.0);
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }
    canvas.drawPath(path, linePaint);

    for (int i = 0; i < values.length; i++) {
      final dx = chartRect.left + chartRect.width * (i / (values.length - 1));
      final dy = chartRect.bottom - chartRect.height * (values[i] / 100.0);
      final point = Offset(dx, dy);
      canvas.drawCircle(point, 4.4, fillPointPaint);
      canvas.drawCircle(point, 4.4, pointOutlinePaint);
    }

    final tp = TextPainter(textDirection: TextDirection.ltr);
    const axisMarks = [0, 25, 50, 75, 100];

    for (int i = 0; i < axisMarks.length; i++) {
      final mark = axisMarks[i];
      tp.text = TextSpan(
        text: '$mark',
        style: TextStyle(
          color: p.dimText,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      );
      tp.layout();

      final x = chartRect.left + chartRect.width * (i / 4) - (tp.width / 2);
      tp.paint(canvas, Offset(x, chartRect.bottom + 2));

      final y = chartRect.bottom - chartRect.height * (i / 4) - (tp.height / 2);
      tp.paint(canvas, Offset(chartRect.left - tp.width - 4, y));
    }

    tp.text = TextSpan(
      text: 'IN %',
      style: TextStyle(
        color: p.dimText,
        fontSize: 9,
        fontWeight: FontWeight.bold,
      ),
    );
    tp.layout();
    tp.paint(canvas, Offset(chartRect.right - tp.width, chartRect.bottom + 2));

    tp.text = TextSpan(
      text: 'OUT %',
      style: TextStyle(
        color: p.dimText,
        fontSize: 9,
        fontWeight: FontWeight.bold,
      ),
    );
    tp.layout();
    tp.paint(canvas, Offset(chartRect.left, chartRect.top - tp.height - 2));
  }

  @override
  bool shouldRepaint(covariant _ThrottleMapPainter oldDelegate) {
    if (oldDelegate.values.length != values.length) {
      return true;
    }
    for (int i = 0; i < values.length; i++) {
      if ((oldDelegate.values[i] - values[i]).abs() > 0.01) {
        return true;
      }
    }
    return oldDelegate.p.light != p.light;
  }
}

// =============================================================================
// PAGE 3: CONFIG / SETTINGS
// =============================================================================
enum _ConfigSection {
  connectivity,
  canDictionary,
  throttle,
  session,
  alerts,
  storage,
  display,
}

class _ConfigView extends StatefulWidget {
  final DashboardState state;
  final _Palette p;
  const _ConfigView({required this.state, required this.p});

  @override
  State<_ConfigView> createState() => _ConfigViewState();
}

class _ConfigViewState extends State<_ConfigView> {
  _ConfigSection _selectedSection = _ConfigSection.connectivity;
  final TextEditingController _canSearchController = TextEditingController();
  final MapController _geofenceMapController = MapController();
  String _canSearchQuery = '';
  bool _geofenceDraftInitialized = false;
  bool _isDrawingGeofence = false;
  LatLng? _draftGeofenceStart;
  LatLng? _draftGeofenceEnd;

  DashboardState get state => widget.state;
  _Palette get p => widget.p;

  @override
  void dispose() {
    _canSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final railWidth = width < 980 ? 188.0 : 224.0;

    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: railWidth, child: _buildMenuRail()),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: KeyedSubtree(
                  key: ValueKey(_selectedSection),
                  child: _buildSelectedSection(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuRail() {
    final items = <({_ConfigSection section, String label, IconData icon})>[
      (
        section: _ConfigSection.connectivity,
        label: 'Connectivity',
        icon: Icons.usb_rounded,
      ),
      (
        section: _ConfigSection.canDictionary,
        label: 'CAN Dictionary',
        icon: Icons.menu_book_rounded,
      ),
      (
        section: _ConfigSection.throttle,
        label: 'Throttle',
        icon: Icons.timeline_rounded,
      ),
      (
        section: _ConfigSection.session,
        label: 'Session Rules',
        icon: Icons.flag_rounded,
      ),
      (
        section: _ConfigSection.alerts,
        label: 'Alerts',
        icon: Icons.notifications_active_rounded,
      ),
      (
        section: _ConfigSection.storage,
        label: 'Storage',
        icon: Icons.sd_storage_rounded,
      ),
      (
        section: _ConfigSection.display,
        label: 'Display/Drive',
        icon: Icons.tune_rounded,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.border, width: 1),
        color: p.light ? Colors.white : const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = _selectedSection == item.section;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                setState(() {
                  _selectedSection = item.section;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? p.cyan : p.border),
                  color: selected
                      ? p.cyan.withValues(alpha: 0.12)
                      : Colors.transparent,
                ),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      size: 16,
                      color: selected ? p.cyan : p.dimText,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.label,
                        style: TextStyle(
                          color: selected ? p.cyan : p.mainText,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedSection(BuildContext context) {
    switch (_selectedSection) {
      case _ConfigSection.connectivity:
        return _buildConnectivitySection();
      case _ConfigSection.canDictionary:
        return _buildCanDictionarySection();
      case _ConfigSection.throttle:
        return _buildThrottleSection(context);
      case _ConfigSection.session:
        return _buildSessionSection(context);
      case _ConfigSection.alerts:
        return _buildAlertsSection();
      case _ConfigSection.storage:
        return _buildStorageSection();
      case _ConfigSection.display:
        return _buildDisplaySection();
    }
  }

  Widget _buildConnectivitySection() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Connectivity Status',
            subtitle: 'Quick health snapshot for telemetry links.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _infoRow('BAUD RATE', '500000'),
                _infoRow(
                  'CAN IDs',
                  '${state.lastCanPayloads.length} active',
                  valueColor: state.lastCanPayloads.isEmpty ? p.red : p.green,
                ),
                _infoRow(
                  'USB',
                  state.isConnected ? 'CONNECTED' : 'DISCONNECTED',
                  valueColor: state.isConnected
                      ? p.green
                      : (p.light ? Colors.grey.shade500 : p.amber),
                ),
                _infoRow(
                  'SIM',
                  state.isSimulated ? 'ACTIVE' : 'OFF',
                  valueColor: state.isSimulated ? p.amber : p.dimText,
                ),
                _infoRow(
                  'MQTT',
                  state.isServerConnected ? 'ONLINE' : 'OFFLINE',
                  valueColor: state.isServerConnected ? p.cyan : p.red,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _buildCmdBtn('RESET CAN LOGS', () {
            setState(() {
              state.lastCanPayloads.clear();
            });
          }),
        ],
      ),
    );
  }

  Widget _buildCanDictionarySection() {
    final query = _canSearchQuery.trim().toLowerCase();
    final filteredEntries = CanDictionary.entries
        .where((entry) {
          if (query.isEmpty) {
            return true;
          }
          final haystack =
              '${entry.hexId} ${entry.key} ${entry.label} ${entry.direction} ${entry.decodeNotes}'
                  .toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'CAN Dictionary',
            subtitle: 'Reference of decoded CAN IDs and payload meanings.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _canSearchController,
                  style: TextStyle(color: p.mainText, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: 'Search by ID/name',
                    labelStyle: TextStyle(color: p.dimText),
                    prefixIcon: Icon(Icons.search_rounded, color: p.dimText),
                    suffixIcon: _canSearchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear_rounded, color: p.dimText),
                            onPressed: () {
                              _canSearchController.clear();
                              setState(() {
                                _canSearchQuery = '';
                              });
                            },
                          ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _canSearchQuery = value;
                    });
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  'MATCHES: ${filteredEntries.length}',
                  style: TextStyle(
                    color: p.dimText,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 380),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.border),
                    color: p.light
                        ? Colors.grey.shade100
                        : const Color(0xFF101010),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: filteredEntries.isEmpty
                      ? Center(
                          child: Text(
                            'No dictionary entries match your search.',
                            style: TextStyle(color: p.dimText, fontSize: 11),
                          ),
                        )
                      : ListView.separated(
                          itemCount: filteredEntries.length,
                          separatorBuilder: (_, __) =>
                              Divider(color: p.border, height: 12),
                          itemBuilder: (context, index) {
                            final entry = filteredEntries[index];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(color: p.border),
                                        color: p.light
                                            ? Colors.white
                                            : const Color(0xFF181818),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        entry.hexId,
                                        style: TextStyle(
                                          color: p.cyan,
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.label,
                                            style: TextStyle(
                                              color: p.mainText,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${entry.direction} | DLC ${entry.expectedDlc} | key: ${entry.key}',
                                            style: TextStyle(
                                              color: p.dimText,
                                              fontFamily: 'monospace',
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  entry.decodeNotes,
                                  style: TextStyle(
                                    color: p.dimText,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeofenceEditorCard(BuildContext context) {
    _ensureGeofenceDraftInitialized();

    final center = _resolveGeofenceMapCenter();
    final hasDraft = _draftGeofenceStart != null && _draftGeofenceEnd != null;
    final polylinePoints = <LatLng>[
      if (_draftGeofenceStart != null) _draftGeofenceStart!,
      if (_draftGeofenceEnd != null) _draftGeofenceEnd!,
    ];

    return _settingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _configSwitch('DRAW MODE', _isDrawingGeofence, (val) {
                  setState(() {
                    _isDrawingGeofence = val;
                  });
                }),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _isDrawingGeofence
                ? 'Tap once for line START, tap again for line END. Further taps move nearest endpoint.'
                : 'Enable Draw Mode to place or edit line endpoints.',
            style: TextStyle(color: p.dimText, fontSize: 10),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 320,
              child: FlutterMap(
                mapController: _geofenceMapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 17,
                  onTap: (_, point) => _handleGeofenceMapTap(point),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'telemetry_dashboard',
                  ),
                  if (polylinePoints.length == 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: polylinePoints,
                          strokeWidth: 4,
                          color: p.cyan,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (_draftGeofenceStart != null)
                        Marker(
                          point: _draftGeofenceStart!,
                          width: 26,
                          height: 26,
                          child: _buildGeofenceMarker('A', p.green),
                        ),
                      if (_draftGeofenceEnd != null)
                        Marker(
                          point: _draftGeofenceEnd!,
                          width: 26,
                          height: 26,
                          child: _buildGeofenceMarker('B', p.orange),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          _infoRow('START', _formatLatLng(_draftGeofenceStart)),
          _infoRow('END', _formatLatLng(_draftGeofenceEnd)),
          _infoRow(
            'CURRENT GPS',
            _currentGpsText,
            valueColor: state.hasCurrentGpsSample
                ? (state.gpsLocked ? p.lightGreen : p.orange)
                : p.dimText,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildCmdBtn('SNAP TO CURRENT GPS', () {
                  _snapDraftLineToCurrentGps(context);
                }, compact: true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildCmdBtn('RESET TO ACTIVE', () {
                  setState(() {
                    _geofenceDraftInitialized = false;
                    _isDrawingGeofence = false;
                  });
                }, compact: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildCmdBtn('CLEAR DRAFT', () {
                  setState(() {
                    _draftGeofenceStart = null;
                    _draftGeofenceEnd = null;
                  });
                }, compact: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildCmdBtn('APPLY LINE', () {
                  if (!hasDraft) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Place both START and END points before applying geofence.',
                        ),
                      ),
                    );
                    return;
                  }

                  state.configureLapBoundary(
                    start: GeoPoint(
                      lat: _draftGeofenceStart!.latitude,
                      lon: _draftGeofenceStart!.longitude,
                    ),
                    end: GeoPoint(
                      lat: _draftGeofenceEnd!.latitude,
                      lon: _draftGeofenceEnd!.longitude,
                    ),
                  );
                  setState(() {
                    _isDrawingGeofence = false;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Lap crossing geofence updated.'),
                    ),
                  );
                }, compact: true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGeofenceMarker(String label, Color color) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: p.bg, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: p.light ? Colors.white : Colors.black,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  void _handleGeofenceMapTap(LatLng point) {
    if (!_isDrawingGeofence) {
      return;
    }

    setState(() {
      if (_draftGeofenceStart == null) {
        _draftGeofenceStart = point;
        return;
      }

      if (_draftGeofenceEnd == null) {
        _draftGeofenceEnd = point;
        return;
      }

      final distance = const Distance();
      final toStart = distance.as(
        LengthUnit.Meter,
        _draftGeofenceStart!,
        point,
      );
      final toEnd = distance.as(LengthUnit.Meter, _draftGeofenceEnd!, point);
      if (toStart <= toEnd) {
        _draftGeofenceStart = point;
      } else {
        _draftGeofenceEnd = point;
      }
    });
  }

  String get _currentGpsText {
    final point = state.currentGpsPoint;
    if (point == null) {
      return '--';
    }
    final source = (state.currentGpsSource ?? state.gpsSourceText)
        .toUpperCase();
    return '${point.lat.toStringAsFixed(6)}, ${point.lon.toStringAsFixed(6)} [$source]';
  }

  void _snapDraftLineToCurrentGps(BuildContext context) {
    final point = state.currentGpsPoint;
    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No current GPS fix available yet.')),
      );
      return;
    }

    final center = LatLng(point.lat, point.lon);
    final headingDeg = state.currentGpsHeadingDeg ?? 0.0;
    const halfLineLengthMeters = 5.0;

    final start = _offsetByBearingMeters(
      origin: center,
      distanceMeters: halfLineLengthMeters,
      bearingDeg: headingDeg - 90.0,
    );
    final end = _offsetByBearingMeters(
      origin: center,
      distanceMeters: halfLineLengthMeters,
      bearingDeg: headingDeg + 90.0,
    );

    setState(() {
      _draftGeofenceStart = start;
      _draftGeofenceEnd = end;
      _geofenceDraftInitialized = true;
      _isDrawingGeofence = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _geofenceMapController.move(center, 18.0);
    });

    final source = (state.currentGpsSource ?? state.gpsSourceText)
        .toUpperCase();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Draft line snapped to current GPS ($source).')),
    );
  }

  LatLng _offsetByBearingMeters({
    required LatLng origin,
    required double distanceMeters,
    required double bearingDeg,
  }) {
    final bearingRad = bearingDeg * pi / 180.0;
    final eastMeters = sin(bearingRad) * distanceMeters;
    final northMeters = cos(bearingRad) * distanceMeters;
    return _offsetByMeters(
      origin: origin,
      eastMeters: eastMeters,
      northMeters: northMeters,
    );
  }

  LatLng _offsetByMeters({
    required LatLng origin,
    required double eastMeters,
    required double northMeters,
  }) {
    const metersPerDegreeLat = 111320.0;
    final lat = origin.latitude + (northMeters / metersPerDegreeLat);
    final metersPerDegreeLon =
        metersPerDegreeLat * cos(origin.latitude * pi / 180.0);
    final safeMetersPerDegreeLon = max(metersPerDegreeLon.abs(), 1.0);
    final lon = origin.longitude + (eastMeters / safeMetersPerDegreeLon);
    return LatLng(lat, lon);
  }

  void _ensureGeofenceDraftInitialized() {
    if (_geofenceDraftInitialized) {
      return;
    }

    final start = _geoPointToLatLng(state.lapBoundaryStart);
    final end = _geoPointToLatLng(state.lapBoundaryEnd);

    _draftGeofenceStart = _isDefaultZeroPoint(start) ? null : start;
    _draftGeofenceEnd = _isDefaultZeroPoint(end) ? null : end;
    _geofenceDraftInitialized = true;
  }

  LatLng _geoPointToLatLng(GeoPoint point) {
    return LatLng(point.lat, point.lon);
  }

  bool _isDefaultZeroPoint(LatLng point) {
    return point.latitude.abs() < 0.000001 && point.longitude.abs() < 0.000001;
  }

  LatLng _resolveGeofenceMapCenter() {
    if (_draftGeofenceStart != null && _draftGeofenceEnd != null) {
      return LatLng(
        (_draftGeofenceStart!.latitude + _draftGeofenceEnd!.latitude) / 2,
        (_draftGeofenceStart!.longitude + _draftGeofenceEnd!.longitude) / 2,
      );
    }

    if (_draftGeofenceStart != null) {
      return _draftGeofenceStart!;
    }
    if (_draftGeofenceEnd != null) {
      return _draftGeofenceEnd!;
    }

    return const LatLng(14.5660, 120.9920);
  }

  String _formatLatLng(LatLng? point) {
    if (point == null) {
      return '--';
    }
    return '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  }

  Widget _buildThrottleSection(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Throttle Mapping',
            subtitle:
                'Edit curve safely in draft mode, then explicitly flash to controller.',
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (state.throttleMapPresetNames.contains('Default'))
                ChoiceChip(
                  label: const Text('Default'),
                  selected: state.selectedThrottleMapProfile == 'Default',
                  selectedColor: p.orange.withValues(alpha: 0.16),
                  side: BorderSide(
                    color: state.selectedThrottleMapProfile == 'Default'
                        ? p.orange
                        : p.border,
                  ),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  labelStyle: TextStyle(
                    color: state.selectedThrottleMapProfile == 'Default'
                        ? p.orange
                        : p.dimText,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  onSelected: (_) {
                    state.loadThrottleMapPreset('Default');
                  },
                ),
              ...state.customThrottleMapPresetNames
                  .where((name) => name != 'Default')
                  .map((profileName) {
                    final selected =
                        state.selectedThrottleMapProfile == profileName;
                    return ChoiceChip(
                      label: Text(profileName),
                      selected: selected,
                      selectedColor: p.orange.withValues(alpha: 0.16),
                      side: BorderSide(color: selected ? p.orange : p.border),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      labelStyle: TextStyle(
                        color: selected ? p.orange : p.dimText,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      onSelected: (_) {
                        state.loadThrottleMapPreset(profileName);
                      },
                    );
                  }),
              InkWell(
                onTap: () => _showAddThrottleProfileDialog(context),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    border: Border.all(color: p.border),
                    color: p.light
                        ? Colors.grey.shade100
                        : const Color(0xFF111111),
                  ),
                  child: Icon(Icons.add_rounded, size: 15, color: p.cyan),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 230,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final chartSize = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (details) {
                    _updateThrottleMapFromGraph(
                      state,
                      details.localPosition,
                      chartSize,
                    );
                  },
                  onPanUpdate: (details) {
                    _updateThrottleMapFromGraph(
                      state,
                      details.localPosition,
                      chartSize,
                    );
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: p.border),
                      color: p.light
                          ? Colors.grey.shade100
                          : const Color(0xFF101010),
                    ),
                    child: CustomPaint(
                      painter: _ThrottleMapPainter(
                        p: p,
                        values: state.throttleMapDraft,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: List.generate(5, (index) {
              final inVal = index * 25;
              final outVal = state.throttleMapDraft[index]
                  .toStringAsFixed(0)
                  .padLeft(3, ' ');
              return Text(
                '$inVal% -> $outVal%',
                style: TextStyle(
                  color: p.mainText,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              border: Border.all(
                color: state.throttleMapDirty ? p.amber : p.border,
                width: 1,
              ),
              color: p.light ? Colors.grey.shade100 : const Color(0xFF101010),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    state.throttleMapDirty
                        ? 'UNFLASHED CHANGES'
                        : 'MAP FLASHED',
                    style: TextStyle(
                      color: state.throttleMapDirty ? p.amber : p.green,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
                if (state.selectedThrottleMapProfile.isEmpty)
                  Text(
                    'UNSAVED PROFILE',
                    style: TextStyle(
                      color: p.cyan,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                if (state.throttleMapDirty)
                  InkWell(
                    onTap: state.resetThrottleMapDraftToApplied,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        'REVERT',
                        style: TextStyle(
                          color: p.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () {
              state.applyThrottleMapDraft();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Throttle map flashed to controller.'),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.red.withValues(alpha: 0.16),
                border: Border.all(color: p.red, width: 1.5),
              ),
              child: Text(
                'FLASH TO CONTROLLER',
                style: TextStyle(
                  color: p.red,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSection(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Session Rules',
            subtitle: 'Applies to the next Start Session flow.',
          ),
          _settingsCard(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'PLANNED LAPS',
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      state.lapsPlanned.toString(),
                      style: TextStyle(
                        color: p.lightGreen,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: state.lapsPlanned.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  activeColor: p.lightGreen,
                  onChanged: (val) => state.setLapsPlanned(val.round()),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'CROSSING DEADZONE',
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      state.crossingDeadzoneConfigText,
                      style: TextStyle(
                        color: p.orange,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: state.crossingDeadzoneMs.toDouble(),
                  min: 1000,
                  max: 10000,
                  divisions: 18,
                  activeColor: p.orange,
                  onChanged: (val) =>
                      state.setCrossingDeadzoneMs(((val / 500).round() * 500)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildSectionHeader(
            title: 'Lap Crossing Geofence',
            subtitle:
                'Draw the finish line directly on the map and apply it to lap detection.',
          ),
          _buildGeofenceEditorCard(context),
        ],
      ),
    );
  }

  Widget _buildAlertsSection() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Driver Alert Channels',
            subtitle: 'Tune non-visual alert behavior.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _configSwitch(
                    'ALERT AUDIO',
                    state.alertAudioEnabled,
                    (val) => state.setAlertAudioEnabled(val),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _configSwitch(
                    'ALERT HAPTICS',
                    state.alertHapticsEnabled,
                    (val) => state.setAlertHapticsEnabled(val),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _configSwitch(
                    'ADVISORY CUES',
                    state.alertAdvisoryEnabled,
                    (val) => state.setAlertAdvisoryEnabled(val),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'ALERT VOLUME',
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      state.alertVolumePercentText,
                      style: TextStyle(
                        color: p.cyan,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: state.alertVolume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  activeColor: p.orange,
                  onChanged: (val) => state.setAlertVolume(val),
                ),
                _buildCmdBtn('TEST ALERT TONE', () {
                  state.requestAlertTestTone();
                }, compact: true),
                const SizedBox(height: 8),
                Text(
                  'LAST ALERT: ${state.lastAlertSeverityText} ${state.lastAlertCode}',
                  style: TextStyle(
                    color: p.dimText,
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageSection() {
    final activeSessionId = state.sessionId.isEmpty
        ? 'pending-session'
        : state.sessionId;
    final normalizedSessionId = activeSessionId.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final activeSessionCsvPath = state.readableCopyDirectoryPath == null
        ? '--'
        : '${state.readableCopyDirectoryPath}/session_$normalizedSessionId.csv';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Session CSV Storage',
            subtitle: 'Writes telemetry to one CSV per session/start.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _infoRow(
                  'MODE',
                  'CSV PER SESSION START',
                  valueColor: p.lightGreen,
                ),
                _infoRow('ACTIVE SESSION', activeSessionId, valueColor: p.cyan),
                _infoRow(
                  'SESSION NAME',
                  state.sessionName.isEmpty ? '--' : state.sessionName,
                ),
                _infoRow('SESSION STATE', state.sessionStateWire),
                _infoRow('ACTIVE CSV', activeSessionCsvPath),
                if (state.readableCopyDirectoryPath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'CSV DIR: ${state.readableCopyDirectoryPath}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.dimText,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'A CSV file is appended during LOGGING for each active session.',
                  style: TextStyle(
                    color: p.dimText,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (state.readableCopyPreviewError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    state.readableCopyPreviewError!,
                    style: TextStyle(
                      color: p.red,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDisplaySection() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(
            title: 'Display & Drive Settings',
            subtitle: 'Runtime UI and driver-assist configuration.',
          ),
          _settingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _configSwitch(
                  'LIGHT THEME (TRACK DAY)',
                  state.useLightTheme,
                  (val) => state.toggleTheme(val),
                ),
                const SizedBox(height: 8),
                _configSwitch(
                  'ENABLE MOCK SIMULATION',
                  state.enableSimulation,
                  (val) => state.toggleSimulation(val),
                ),
                const SizedBox(height: 8),
                _configSwitch(
                  'USE DICTIONARY TX FOR AUX COMMANDS',
                  state.useDictionaryAuxDispatch,
                  (val) => state.toggleDictionaryAuxDispatch(val),
                ),
                const SizedBox(height: 12),
                Text(
                  'GRAPH METRIC',
                  style: TextStyle(
                    color: p.dimText,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: state.graphMetric,
                  dropdownColor: p.light
                      ? Colors.white
                      : const Color(0xFF1E1E1E),
                  style: TextStyle(
                    color: p.cyan,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'speed', child: Text('SPEED')),
                    DropdownMenuItem(value: 'power', child: Text('POWER (W)')),
                    DropdownMenuItem(
                      value: 'efficiency',
                      child: Text('EFFICIENCY'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) state.updateGraphMetric(val);
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'SPEED BAR THRESHOLDS',
                  style: TextStyle(
                    color: p.dimText,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: state.speedLowerThreshold.toStringAsFixed(
                          0,
                        ),
                        style: TextStyle(
                          color: p.cyan,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          labelText: 'BURN ↓',
                          labelStyle: TextStyle(color: p.dimText, fontSize: 10),
                          filled: true,
                          fillColor: p.light
                              ? Colors.grey.shade200
                              : Colors.black,
                          contentPadding: const EdgeInsets.all(8),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          final v = double.tryParse(val);
                          if (v != null) {
                            state.updateSpeedThresholds(
                              v,
                              state.speedUpperThreshold,
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        initialValue: state.speedUpperThreshold.toStringAsFixed(
                          0,
                        ),
                        style: TextStyle(
                          color: p.orange,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          labelText: 'COAST ↑',
                          labelStyle: TextStyle(color: p.dimText, fontSize: 10),
                          filled: true,
                          fillColor: p.light
                              ? Colors.grey.shade200
                              : Colors.black,
                          contentPadding: const EdgeInsets.all(8),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          final v = double.tryParse(val);
                          if (v != null) {
                            state.updateSpeedThresholds(
                              state.speedLowerThreshold,
                              v,
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddThrottleProfileDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: p.light ? Colors.white : const Color(0xFF121212),
          title: Text(
            'Save Throttle Profile',
            style: TextStyle(color: p.mainText, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: p.cyan, fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: 'Profile Name',
              labelStyle: TextStyle(color: p.dimText),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CANCEL', style: TextStyle(color: p.dimText)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('SAVE'),
            ),
          ],
        );
      },
    );

    if (!context.mounted || name == null) {
      return;
    }

    final saved = state.addThrottleMapPreset(name);
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Unable to save profile. Use a unique non-default name.',
          ),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Profile "$name" saved.')));
  }

  void _updateThrottleMapFromGraph(
    DashboardState state,
    Offset localPosition,
    Size size,
  ) {
    const pad = 18.0;
    final chartWidth = max(1.0, size.width - (pad * 2));
    final chartHeight = max(1.0, size.height - (pad * 2));

    final normalizedX = ((localPosition.dx - pad) / chartWidth).clamp(0.0, 1.0);
    final index = (normalizedX * 4).round().clamp(0, 4);

    final normalizedY = ((chartHeight - (localPosition.dy - pad)) / chartHeight)
        .clamp(0.0, 1.0);
    final outputPercent = normalizedY * 100.0;

    state.updateThrottleMap(index, outputPercent);
  }

  String _formatUtcTimestamp(DateTime? valueUtc) {
    if (valueUtc == null) {
      return '--';
    }
    final ts = valueUtc.toUtc();
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    return '$hh:$mm:${ss}Z';
  }

  Widget _buildSectionHeader({required String title, String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: p.mainText,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: p.dimText, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _settingsCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: p.border, width: 1),
        color: p.light ? Colors.white : const Color(0xFF101010),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  Widget _configSwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(
                color: p.dimText,
                fontWeight: FontWeight.bold,
                fontSize: 10,
              ),
            ),
          ),
        ),
        Switch(value: value, activeThumbColor: p.amber, onChanged: onChanged),
      ],
    );
  }

  Widget _infoRow(String label, String val, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.dimText,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            val,
            style: TextStyle(
              color: valueColor ?? p.mainText,
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCmdBtn(
    String label,
    VoidCallback onTap, {
    bool compact = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
        decoration: BoxDecoration(
          border: Border.all(color: p.dimText),
          color: p.light ? Colors.grey.shade200 : const Color(0xFF141414),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: p.mainText,
            fontWeight: FontWeight.bold,
            fontSize: compact ? 10 : 12,
          ),
        ),
      ),
    );
  }
}
