import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
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

                // RIGHT COL: Avg Eff → Fault+Strategy → Rolling Graph
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: _buildSplitCell(
                          "AVG EFF. / ENERGY",
                          state.avgKmPerKwh.toStringAsFixed(1).padLeft(5, '0'),
                          "km/kWh",
                          (state.energyJ780 / 3600.0)
                              .toStringAsFixed(1)
                              .padLeft(5, '0'),
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
              child: _buildFlChartGraph(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlChartGraph() {
    final data = state.graphHistory.toList();
    if (data.length < 2) return const SizedBox();

    final double gMin = state.graphYMin;
    final double gMax = state.graphYMax;
    final range = gMax - gMin == 0 ? 1.0 : gMax - gMin;

    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i]));
    }

    // Fixed color as requested
    Color lineColor = p.cyan;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: max(range / 4, 1.0),
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: p.border.withValues(alpha: 0.5),
              strokeWidth: 1,
            );
          },
          getDrawingVerticalLine: (value) {
            return FlLine(
              color: p.border.withValues(alpha: 0.5),
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: max(range / 2, 1.0),
              reservedSize: 32,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toStringAsFixed(0),
                  style: TextStyle(
                    color: p.dimText,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minX: 0,
        maxX: (data.length - 1).toDouble(),
        minY: gMin,
        maxY: gMax,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.2),
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
                            : state.instKmPerKwh
                                  .toStringAsFixed(1)
                                  .padLeft(5, '0'),
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
