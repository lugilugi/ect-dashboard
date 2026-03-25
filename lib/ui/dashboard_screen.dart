import 'dart:ui';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/dashboard_state.dart';

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
// ROOT SCREEN: PageView with 3 pages
// =============================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final PageController _pageController = PageController();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<DashboardState>();
    final p = _Palette(state.useLightTheme);

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
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _EfficiencyGrid(state: state, p: p),
                    _EngineerView(state: state, p: p),
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
    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border.all(color: p.border, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              _buildIndicator(
                Icons.keyboard_arrow_left,
                state.leftTurn,
                p.green,
                p,
                onTap: () => state.sendUsbCommand("CMD:LEFT_TURN\n"),
              ),
              _buildIndicator(
                Icons.lightbulb,
                state.headlights,
                Colors.blueAccent,
                p,
                onTap: () => state.sendUsbCommand("CMD:HEADLIGHTS\n"),
              ),
              _buildIndicator(
                Icons.waves,
                state.wipers,
                p.cyan,
                p,
                onTap: () => state.sendUsbCommand("CMD:WIPERS\n"),
              ),
              _buildIndicator(
                Icons.volume_up,
                state.horn,
                p.orange,
                p,
                onTap: () => state.sendUsbCommand("CMD:HORN\n"),
              ),
              _buildIndicator(
                Icons.warning,
                state.hazards,
                p.red,
                p,
                onTap: () => state.sendUsbCommand("CMD:HAZARDS\n"),
              ),
              _buildIndicator(
                Icons.keyboard_arrow_right,
                state.rightTurn,
                p.green,
                p,
                onTap: () => state.sendUsbCommand("CMD:RIGHT_TURN\n"),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Row(
              children: [
                Icon(
                  Icons.satellite_alt,
                  color: state.gpsLocked ? p.cyan : p.red,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  state.gpsLocked
                      ? "3D FIX (${state.gpsSatellites})"
                      : "NO FIX",
                  style: TextStyle(
                    color: state.gpsLocked ? p.cyan : p.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 16),
                Icon(
                  Icons.warning_amber_rounded,
                  color: state.errorCount > 0 ? p.red : p.border,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  "ERR: ${state.errorCount}",
                  style: TextStyle(
                    color: state.errorCount > 0 ? p.red : p.dimText,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  "LOCAL ",
                  style: TextStyle(
                    color: p.dimText,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  state.systemTimeString,
                  style: TextStyle(
                    color: p.amber,
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 24),
                Icon(
                  Icons.memory,
                  color: state.isSimulated ? p.amber : p.border,
                  size: 10,
                ),
                const SizedBox(width: 4),
                Text(
                  "SIM",
                  style: TextStyle(
                    color: state.isSimulated ? p.amber : p.border,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 16),
                Icon(
                  Icons.circle,
                  color: state.isConnected ? p.green : p.red,
                  size: 10,
                ),
                const SizedBox(width: 4),
                Text(
                  "USB",
                  style: TextStyle(
                    color: state.isConnected ? p.green : p.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 16),
                Icon(
                  Icons.cloud_circle,
                  color: state.isServerConnected ? p.cyan : p.red,
                  size: 10,
                ),
                const SizedBox(width: 4),
                Text(
                  "API",
                  style: TextStyle(
                    color: state.isServerConnected ? p.cyan : p.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndicator(
    IconData icon,
    bool active,
    Color color,
    _Palette p, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 48,
        height: double.infinity,
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          border: Border(right: BorderSide(color: p.border, width: 1)),
        ),
        child: Icon(
          icon,
          color: active ? (p.light ? Colors.white : Colors.black) : p.border,
          size: 24,
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
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
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
      height: 48,
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

// =============================================================================
// PAGE 2: ENGINEER DIAGNOSTICS
// =============================================================================
class _EngineerView extends StatelessWidget {
  final DashboardState state;
  final _Palette p;
  const _EngineerView({required this.state, required this.p});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: _buildPanel(
              title: "ACTIVE CAN BUS NODES",
              child: ListView(
                children: state.lastCanPayloads.entries.map((e) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "0x${e.key.toRadixString(16).toUpperCase().padLeft(3, '0')}",
                          style: TextStyle(
                            color: p.cyan,
                            fontFamily: 'monospace',
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          e.value.padRight(16, ' '),
                          style: TextStyle(
                            color: p.mainText,
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 3,
            child: _buildPanel(
              title: "BATTERY MANAGEMENT CELL VOLTAGES",
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 8,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                  childAspectRatio: 1.3,
                ),
                itemCount: state.bmsCells.length,
                itemBuilder: (context, index) {
                  double v = state.bmsCells[index];
                  Color c = v > 3.75 ? p.green : (v >= 3.7 ? p.yellow : p.red);
                  return Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: p.border, width: 1),
                      color: p.light
                          ? Colors.grey.shade100
                          : const Color(0xFF141414),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 2,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "C${index + 1}",
                          style: TextStyle(
                            color: p.dimText,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: Text(
                              v.toStringAsFixed(2),
                              style: TextStyle(
                                color: c,
                                fontFamily: 'monospace',
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(
                  flex: 1,
                  child: _buildPanel(
                    title: "12V MASTER BUS",
                    child: Center(
                      child: Text(
                        "${state.bus12V.toStringAsFixed(1)} v",
                        style: TextStyle(
                          color: p.yellow,
                          fontSize: 60,
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  flex: 2,
                  child: _buildPanel(
                    title: "M.C. FAULT CODES",
                    child: ListView(
                      children: state.mcFaults
                          .map(
                            (f) => Text(
                              f,
                              style: TextStyle(
                                color: f == "NONE" ? p.green : p.red,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                          .toList(),
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

  Widget _buildPanel({required String title, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: p.border, width: 1),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.border, width: 1)),
            ),
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
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// =============================================================================
// PAGE 3: CONFIG / SETTINGS
// =============================================================================
class _ConfigView extends StatelessWidget {
  final DashboardState state;
  final _Palette p;
  const _ConfigView({required this.state, required this.p});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // LEFT: HARDWARE SNAPSHOT
          Expanded(
            flex: 2,
            child: _buildPanel(
              "HARDWARE SNAPSHOT",
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow("BAUD RATE", "500000"),
                  _infoRow("CAN IDs", "${state.lastCanPayloads.length} active"),
                  _infoRow(
                    "USB",
                    state.isConnected ? "CONNECTED" : "DISCONNECTED",
                  ),
                  _infoRow("SIM", state.isSimulated ? "ACTIVE" : "OFF"),
                  const Spacer(),
                  _buildCmdBtn("RESET CAN LOGS", () {
                    state.lastCanPayloads.clear();
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),

          // CENTER: THROTTLE MAPPING
          Expanded(
            flex: 3,
            child: _buildPanel(
              "THROTTLE RAMP MAPPING (0-100%)",
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(5, (index) {
                  return Column(
                    children: [
                      Text(
                        "${index * 25}% IN",
                        style: TextStyle(
                          color: p.dimText,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: -1,
                          child: Slider(
                            value: state.throttleMap[index],
                            min: 0,
                            max: 100,
                            activeColor: p.orange,
                            onChanged: (val) =>
                                state.updateThrottleMap(index, val),
                          ),
                        ),
                      ),
                      Text(
                        "${state.throttleMap[index].toStringAsFixed(0)}% OUT",
                        style: TextStyle(
                          color: p.mainText,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
          const SizedBox(width: 4),

          // RIGHT: APP CONFIG
          Expanded(
            flex: 2,
            child: _buildPanel(
              "SOFTWARE CONFIGURATION",
              SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Theme toggle
                    _configSwitch(
                      "LIGHT THEME (TRACK DAY)",
                      state.useLightTheme,
                      (val) => state.toggleTheme(val),
                    ),
                    const SizedBox(height: 8),
                    // Sim toggle
                    _configSwitch(
                      "ENABLE MOCK SIMULATION",
                      state.enableSimulation,
                      (val) => state.toggleSimulation(val),
                    ),
                    const SizedBox(height: 12),
                    // Graph metric selector
                    Text(
                      "GRAPH METRIC",
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
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: "speed", child: Text("SPEED")),
                        DropdownMenuItem(
                          value: "power",
                          child: Text("POWER (W)"),
                        ),
                        DropdownMenuItem(
                          value: "efficiency",
                          child: Text("EFFICIENCY"),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) state.updateGraphMetric(val);
                      },
                    ),
                    const SizedBox(height: 12),
                    // Speed thresholds
                    Text(
                      "SPEED BAR THRESHOLDS",
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
                            initialValue: state.speedLowerThreshold
                                .toStringAsFixed(0),
                            style: TextStyle(
                              color: p.cyan,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            decoration: InputDecoration(
                              labelText: "BURN ↓",
                              labelStyle: TextStyle(
                                color: p.dimText,
                                fontSize: 10,
                              ),
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
                              if (v != null)
                                state.updateSpeedThresholds(
                                  v,
                                  state.speedUpperThreshold,
                                );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: state.speedUpperThreshold
                                .toStringAsFixed(0),
                            style: TextStyle(
                              color: p.orange,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            decoration: InputDecoration(
                              labelText: "COAST ↑",
                              labelStyle: TextStyle(
                                color: p.dimText,
                                fontSize: 10,
                              ),
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
                              if (v != null)
                                state.updateSpeedThresholds(
                                  state.speedLowerThreshold,
                                  v,
                                );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // API URL
                    Text(
                      "API SERVER ENDPOINT URL",
                      style: TextStyle(
                        color: p.dimText,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: state.apiUrl,
                      style: TextStyle(
                        color: p.cyan,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: InputDecoration(
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
                      onChanged: (val) => state.updateApiUrl(val),
                    ),
                    const SizedBox(height: 12),
                    _buildCmdBtn("SAVE & RESTART SOCKETS", () {
                      debugPrint("API Service Rebuilding with ${state.apiUrl}");
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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

  Widget _infoRow(String label, String val) {
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
              color: p.mainText,
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(String title, Widget child) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: p.border, width: 1)),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.border, width: 1)),
            ),
            child: Text(
              title,
              style: TextStyle(
                color: p.mainText,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildCmdBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
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
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
