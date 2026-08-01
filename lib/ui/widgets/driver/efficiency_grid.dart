import 'dart:math';
import 'package:flutter/material.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';

// =============================================================================
// PAGE 1: EFFICIENCY GRID (Driver View)
// =============================================================================
class EfficiencyGrid extends StatelessWidget {
  final DashboardState state;
  final Palette p;
  const EfficiencyGrid({super.key, required this.state, required this.p});

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
                          state.mainVoltage.toStringAsFixed(1).padLeft(4, '0'),
                          "V",
                          max(
                            0,
                            state.current780,
                          ).toStringAsFixed(1).padLeft(4, '0'),
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
                          powerW.toStringAsFixed(0).padLeft(4, '0'),
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

                // RIGHT COL: Strat Marker → Avg Eff → Lap/Dist/Avg Speed → Session Time
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: _FlashingStratMarker(state: state, p: p),
                      ),
                      Expanded(child: _buildAvgEffCell()),
                      Expanded(child: _buildLapDistAvgSpeedCell()),
                      Expanded(child: _buildSessionTimeCell()),
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
    final double maxSpeed = 50.0;
    final fraction = (state.speedKmh / maxSpeed).clamp(0.0, 1.0);
    final upperFrac = (state.speedUpperThreshold / maxSpeed).clamp(0.0, 1.0);
    final lowerFrac = (state.speedLowerThreshold / maxSpeed).clamp(0.0, 1.0);

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
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: p.barBg.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: p.border.withValues(alpha: 0.5),
                            width: 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              state.speedKmh.toStringAsFixed(1).padLeft(4, '0'),
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
  // AVG EFF (giant) + Total Energy (corner)
  // ---------------------------------------------------------------------------
  Widget _buildAvgEffCell() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: p.border, width: 1),
          bottom: BorderSide(color: p.border, width: 1),
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
                "AVG EFF",
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
            child: Stack(
              children: [
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          state.avgKmPerKwh.toStringAsFixed(1).padLeft(5, '0'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                            color: p.lightGreen,
                            fontSize: 64,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                          ),
                        ),
                        Text(
                          "km/kWh",
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
                Positioned(
                  right: 8,
                  bottom: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        "ENERGY",
                        style: TextStyle(
                          color: p.dimText,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      Text(
                        "${(state.energyJ780 / 3600.0).toStringAsFixed(1)} Wh",
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                          color: p.purple,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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
  // LAP / DISTANCE (left) | AVG SPEED (right)
  // ---------------------------------------------------------------------------
  Widget _buildLapDistAvgSpeedCell() {
    final elapsedH = state.sessionTimeSeconds / 3600.0;
    final avgSpeedKmh = elapsedH > 0 ? state.distanceKm / elapsedH : 0.0;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: p.border, width: 1),
          bottom: BorderSide(color: p.border, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: _buildLabeledValue(
                    label: "LAP",
                    value: state.lapNumber.toString(),
                    valueColor: p.pink,
                    valueSize: 34,
                  ),
                ),
                Container(width: 1, color: p.border),
                Expanded(
                  flex: 3,
                  child: _buildLabeledValue(
                    label: "DISTANCE",
                    value: state.distanceKm.toStringAsFixed(2),
                    valueColor: p.teal,
                    valueSize: 34,
                    unit: "km",
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: p.border),
          Expanded(
            child: _buildLabeledValue(
              label: "AVG SPEED",
              value: avgSpeedKmh.toStringAsFixed(1).padLeft(4, '0'),
              valueColor: p.lightGreen,
              valueSize: 42,
              unit: "km/h",
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Labeled Value Cell (top-left label + centered value/unit)
  // ---------------------------------------------------------------------------
  Widget _buildLabeledValue({
    required String label,
    required String value,
    required Color valueColor,
    double valueSize = 42,
    String? unit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 6, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: TextStyle(
                color: p.dimText,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: valueColor,
                        fontSize: valueSize,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                    if (unit != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        unit,
                        style: TextStyle(
                          color: p.dimText,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
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
  // SESSION TIME (giant)
  // ---------------------------------------------------------------------------
  Widget _buildSessionTimeCell() {
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.border, width: 1)),
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
                "SESSION TIME",
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
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      state.sessionTimeString,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontFeatures: const [
                          FontFeature.tabularFigures(),
                        ],
                        color: p.amber,
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      state.systemTimeString,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontFeatures: const [
                          FontFeature.tabularFigures(),
                        ],
                        color: p.amber,
                        fontSize: 11,
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
            alignment: Alignment.center,
            child: Text(
              state.throttlePercent >= 100
                  ? "MAX"
                  : "${state.throttlePercent.toStringAsFixed(0).padLeft(2, '0')}%",
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
    return Column(
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
                      : state.instKmPerKwh
                            .toStringAsFixed(1)
                            .padLeft(5, '0'),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: instEffColor,
                    fontSize: 42,
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
    );
  }
}

// -----------------------------------------------------------------------------
// STRAT MARKER (flashing BURN / COAST / HOLD)
// -----------------------------------------------------------------------------
class _FlashingStratMarker extends StatefulWidget {
  final DashboardState state;
  final Palette p;

  const _FlashingStratMarker({required this.state, required this.p});

  @override
  State<_FlashingStratMarker> createState() => _FlashingStratMarkerState();
}

class _FlashingStratMarkerState extends State<_FlashingStratMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.25, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _stratLabel(String strategy) {
    switch (strategy.toUpperCase()) {
      case 'ATTACK':
        return 'BURN';
      case 'REGEN':
        return 'HOLD';
      case 'COAST':
      case 'PACE':
        return 'COAST';
      default:
        return strategy.toUpperCase();
    }
  }

  Color _stratColor(String strategy) {
    switch (strategy.toUpperCase()) {
      case 'ATTACK':
        return widget.p.orange;
      case 'REGEN':
        return widget.p.red;
      case 'COAST':
      case 'PACE':
        return widget.p.cyan;
      default:
        return widget.p.mainText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final state = widget.state;
    final hasFault =
        state.lastErrorCode != 'OK' && state.lastErrorCode != 'NONE';
    final label = hasFault
        ? 'ERR ${state.lastErrorCode}'
        : _stratLabel(state.strategy);
    final color = hasFault ? p.red : _stratColor(state.strategy);

    return Container(
      decoration: BoxDecoration(
        color: hasFault
            ? Colors.red.shade900.withValues(alpha: 0.5)
            : color.withValues(alpha: p.light ? 0.2 : 0.12),
        border: Border(
          left: BorderSide(color: p.border, width: 1),
          bottom: BorderSide(color: p.border, width: 1),
        ),
      ),
      child: FadeTransition(
        opacity: _opacity,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: color,
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.0,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'STRAT',
                    style: TextStyle(
                      color: p.dimText,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
