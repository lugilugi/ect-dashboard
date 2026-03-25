import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/dashboard_state.dart';

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

    return Scaffold(
      backgroundColor: Colors.black, 
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Column(
            children: [
              // TOP STATUS BAR
              _buildCompactStatusBar(state),
              
              // MAIN PAGES
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
                  ),
                  child: PageView(
                    controller: _pageController,
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _EfficiencyGrid(state: state),
                      _EngineerView(state: state),
                      _ConfigView(state: state), // NEW 3RD PAGE
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactStatusBar(DashboardState state) {
    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              _buildIndicator(Icons.keyboard_arrow_left, state.leftTurn, Colors.greenAccent),
              _buildIndicator(Icons.lightbulb, state.headlights, Colors.blueAccent),
              _buildIndicator(Icons.waves, state.wipers, Colors.cyan),
              _buildIndicator(Icons.volume_up, state.horn, Colors.orangeAccent),
              _buildIndicator(Icons.warning, state.hazards, Colors.redAccent),
              _buildIndicator(Icons.keyboard_arrow_right, state.rightTurn, Colors.greenAccent),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Row(
              children: [
                // GPS Lock Setup
                Icon(Icons.satellite_alt, color: state.gpsLocked ? Colors.cyanAccent : Colors.redAccent, size: 14),
                const SizedBox(width: 4),
                Text(
                  state.gpsLocked ? "3D FIX (${state.gpsSatellites})" : "NO FIX",
                  style: TextStyle(color: state.gpsLocked ? Colors.cyanAccent : Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 16),
                
                // Error Counters
                Icon(Icons.warning_amber_rounded, color: state.errorCount > 0 ? Colors.redAccent : Colors.white24, size: 14),
                const SizedBox(width: 4),
                Text(
                  "ERR: ${state.errorCount}", 
                  style: TextStyle(color: state.errorCount > 0 ? Colors.redAccent : Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace', fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                const SizedBox(width: 16),

                // System Time
                const Text("LOCAL ", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                Text(
                  state.systemTimeString,
                  style: const TextStyle(color: Colors.amberAccent, fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()], fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 24),
                
                // USB Status
                Icon(Icons.circle, color: state.isConnected ? Colors.greenAccent : Colors.redAccent, size: 10),
                const SizedBox(width: 4),
                Text("USB", style: TextStyle(color: state.isConnected ? Colors.greenAccent : Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(width: 16),
                
                // SERVER Status
                Icon(Icons.cloud_circle, color: state.isServerConnected ? Colors.cyanAccent : Colors.redAccent, size: 10),
                const SizedBox(width: 4),
                Text("API", style: TextStyle(color: state.isServerConnected ? Colors.cyanAccent : Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildIndicator(IconData icon, bool active, Color color) {
    return Container(
      width: 48,
      height: double.infinity,
      decoration: BoxDecoration(
        color: active ? color : Colors.transparent,
        border: const Border(right: BorderSide(color: Colors.white24, width: 1)),
      ),
      child: Icon(icon, color: active ? Colors.black : Colors.white24, size: 24),
    );
  }
}

// ---------------------------------------------------------
// WINDOW 1: GRID EFFICIENCY MODE
// ---------------------------------------------------------
class _EfficiencyGrid extends StatelessWidget {
  final DashboardState state;
  const _EfficiencyGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    
    // Dynamic neon rules 
    double powerW = state.mainVoltage * state.current780;
    Color powerColor = Colors.white;
    if (powerW < 0) {
      powerColor = Colors.cyanAccent;
    } else if (powerW > 3000) powerColor = Colors.red;
    else if (powerW > 2000) powerColor = Colors.redAccent;
    else if (powerW > 1000) powerColor = Colors.orangeAccent;

    Color instEffColor = state.strategy == "REGEN" ? Colors.cyanAccent : Colors.white;

    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.white24, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // FULL WIDTH MASTER THROTTLE BAR
          _buildGridThrottleBar(),

          // 3-COLUMN DATA GRID
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // LEFT COL
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(child: _buildSplitCell("VOLTAGE / CURRENT", state.mainVoltage.toStringAsFixed(1), "V", state.current780.toStringAsFixed(1), "A", bottomBorder: true, rightBorder: true, color1: Colors.yellowAccent, color2: Colors.cyanAccent)),
                      Expanded(child: _buildGridCell("NODE FAULT CODES", state.lastErrorCode, "", bottomBorder: true, rightBorder: true, valueColor: state.lastErrorCode == "OK" ? Colors.greenAccent : Colors.redAccent)),
                      Expanded(child: _buildGridCell("POWER", powerW.toStringAsFixed(0), "W", bottomBorder: true, rightBorder: true, valueColor: powerColor)),
                      Expanded(child: _buildSplitCell("M.C. TEMP / BATT TEMP", state.mcTempC.toStringAsFixed(0), "°C", state.battTempC.toStringAsFixed(0), "°C", bottomBorder: false, rightBorder: true, color1: state.mcTempC > 80 ? Colors.redAccent : Colors.orangeAccent, color2: state.battTempC > 50 ? Colors.redAccent : Colors.deepOrangeAccent)),
                    ],
                  ),
                ),

                // CENTER COL
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Container(
                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
                          child: _buildCentralEfficiency(instEffColor),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: _buildBottomCenterMetrics(state),
                      ),
                    ],
                  ),
                ),

                // RIGHT COL
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(child: _buildSplitCell("AVG EFF. / ENERGY", state.avgKmPerKwh.toStringAsFixed(2), "km/kWh", (state.energyJ780 / 3600.0).toStringAsFixed(1), "Wh", leftBorder: true, bottomBorder: true, color1: Colors.lightGreenAccent, color2: Colors.purpleAccent)),
                      Expanded(child: _buildBlankCell(bottomBorder: true)),
                      Expanded(child: _buildStrategyCell(bottomBorder: true)),
                      Expanded(child: _buildBlankCell(bottomBorder: false)),
                    ],
                  ),
                ),
              ],
            ),
          )
        ],
      )
    );
  }

  Widget _buildCentralEfficiency(Color accentColor) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: double.infinity,
          color: accentColor,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text("INSTANT km/kWh", textAlign: TextAlign.center, style: TextStyle(color: accentColor == Colors.white ? Colors.black : Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        Expanded(
          child: Center(
            child: Text(
              state.instKmPerKwh > 90.0 ? "MAX " : state.instKmPerKwh.toStringAsFixed(2),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFeatures: const [FontFeature.tabularFigures()],
                fontSize: 100, 
                color: accentColor, 
                fontWeight: FontWeight.bold, 
                height: 1.0, 
                letterSpacing: -2,
              ),
            ),
          ),
        )
      ],
    );
  }

  Widget _buildGridThrottleBar() {
    return Container(
      height: 48,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(color: state.isBrakePressed ? Colors.redAccent : Colors.transparent),
            alignment: Alignment.center,
            child: Text(state.isBrakePressed ? "BRK " : "THR ", style: TextStyle(color: state.isBrakePressed ? Colors.black : Colors.white54, fontWeight: FontWeight.bold, fontSize: 18)),
          ),
          Container(width: 1, color: Colors.white24),
          Expanded(
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                FractionallySizedBox(
                  widthFactor: (state.throttlePercent / 100).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: state.throttlePercent > 85 ? Colors.orangeAccent : Colors.greenAccent,
                      boxShadow: [BoxShadow(color: (state.throttlePercent > 85 ? Colors.orangeAccent : Colors.greenAccent).withOpacity(0.6), blurRadius: 15)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: Colors.white24),
          Container(
            width: 80,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              "${state.throttlePercent.toStringAsFixed(0)}%",
              style: const TextStyle(fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()], color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 22),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSplitCell(String mainTitle, String val1, String unit1, String val2, String unit2, {
    bool leftBorder = false, bool rightBorder = false, bool topBorder = false, bool bottomBorder = false,
    Color color1 = Colors.white, Color color2 = Colors.white,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
           left: leftBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
           right: rightBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
           top: topBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
           bottom: bottomBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 6),
            child: Text(mainTitle, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(val1, style: TextStyle(fontFamily: 'monospace', fontFeatures: const [FontFeature.tabularFigures()], color: color1, fontSize: 42, fontWeight: FontWeight.bold, height: 1.0)),
                        if (unit1.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 4.0), child: Text(unit1, style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold))),
                      ],
                    ),
                  ),
                ),
                Container(width: 1, color: Colors.white24, height: 40),
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(val2, style: TextStyle(fontFamily: 'monospace', fontFeatures: const [FontFeature.tabularFigures()], color: color2, fontSize: 42, fontWeight: FontWeight.bold, height: 1.0)),
                        if (unit2.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 4.0), child: Text(unit2, style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold))),
                      ],
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

  Widget _buildStrategyCell({bool bottomBorder = false}) {
    Color strategyColor = Colors.white;
    if (state.strategy == "BURN") strategyColor = Colors.orangeAccent;
    if (state.strategy == "REGEN") strategyColor = Colors.redAccent;
    if (state.strategy == "COAST") strategyColor = Colors.cyanAccent;
    if (state.strategy == "PACE") strategyColor = Colors.greenAccent;

    return Container(
      decoration: BoxDecoration(
        color: strategyColor,
        border: Border(
           left: const BorderSide(color: Colors.white24, width: 1),
           bottom: bottomBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 6),
            child: Text("STRATEGY TARGET", style: TextStyle(color: Colors.black.withOpacity(0.6), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          ),
          Expanded(
            child: Center(
              child: Text(
                state.strategy,
                textAlign: TextAlign.center,
                style: const TextStyle(
                   fontFamily: 'monospace',
                   color: Colors.black, 
                   fontSize: 56, 
                   fontWeight: FontWeight.w900, 
                   height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridCell(String title, String value, String unit, {
    bool leftBorder = false, bool rightBorder = false, bool topBorder = false, bool bottomBorder = false, Color valueColor = Colors.white
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent, 
        border: Border(
           left: leftBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
           right: rightBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
           top: topBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
           bottom: bottomBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 6),
            child: Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                       fontFamily: 'monospace',
                       fontFeatures: const [FontFeature.tabularFigures()],
                       color: valueColor, 
                       fontSize: 56, 
                       fontWeight: FontWeight.bold, 
                       height: 1.0
                    ),
                  ),
                ),
                SizedBox(
                  width: 50, 
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6.0),
                    child: Text(unit, style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlankCell({bool bottomBorder = true}) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
           left: const BorderSide(color: Colors.white24, width: 1),
           bottom: bottomBorder ? const BorderSide(color: Colors.white24, width: 1) : BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildBottomCenterMetrics(DashboardState state) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LEFT HALF: SPEED
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 8, top: 6),
                child: Text("SPEED", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      state.speedKmh.toStringAsFixed(1).padLeft(4, '0'),
                      style: const TextStyle(fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()], color: Colors.cyanAccent, fontSize: 62, fontWeight: FontWeight.bold, height: 1.0),
                    ),
                    const SizedBox(width: 6),
                    const Text("km/h", style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          )
        ),
        Container(width: 1, color: Colors.white24),
        // RIGHT HALF: SESS, LAP, DIST
        Expanded(
          flex: 3,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
                  child: _buildMiniRow("SESS", state.sessionTimeString, valColor: Colors.amberAccent),
                )
              ),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
                  child: _buildMiniRow("LAP", state.lapNumber.toString(), valColor: Colors.pinkAccent),
                )
              ),
              Expanded(
                child: _buildMiniRow("DIST", "${state.distanceKm.toStringAsFixed(2)} km", valColor: Colors.tealAccent),
              ),
            ],
          )
        )
      ],
    );
  }

  Widget _buildMiniRow(String label, String val, {Color valColor = Colors.white}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
          Text(val, style: TextStyle(fontFamily: 'monospace', fontFeatures: const [FontFeature.tabularFigures()], color: valColor, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// WINDOW 2: ENGINEER DIAGNOSTICS MODE (COMPACT DATA)
// ---------------------------------------------------------
class _EngineerView extends StatelessWidget {
  final DashboardState state;
  const _EngineerView({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // LEFT: CAN RAW LOGS
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
                        Text("0x${e.key.toRadixString(16).toUpperCase().padLeft(3, '0')}", style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.bold)),
                        Text(e.value.padRight(16, ' '), style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13)),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(width: 4),

          // CENTER: BMS CELL MONITOR GRID
          Expanded(
            flex: 3,
            child: _buildPanel(
              title: "BATTERY MANAGEMENT CELL VOLTAGES",
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8, crossAxisSpacing: 2, mainAxisSpacing: 2, childAspectRatio: 1.3),
                itemCount: state.bmsCells.length,
                itemBuilder: (context, index) {
                  double v = state.bmsCells[index];
                  Color c = v > 3.75 ? Colors.greenAccent : (v >= 3.7 ? Colors.yellowAccent : Colors.redAccent);
                  return Container(
                    decoration: BoxDecoration(border: Border.all(color: Colors.white24, width: 1), color: const Color(0xFF141414)),
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("C${index+1}", style: const TextStyle(color: Colors.white54, fontSize: 8, fontWeight: FontWeight.bold)),
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: Text(v.toStringAsFixed(2), style: TextStyle(color: c, fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.bold)),
                          )
                        )
                      ],
                    ),
                  );
                }
              )
            ),
          ),
          const SizedBox(width: 4),

          // RIGHT: 12V AUX & CONTROLLER FAULTS
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
                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 60, fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.bold)
                      ),
                    ),
                  )
                ),
                const SizedBox(height: 4),
                Expanded(
                  flex: 2,
                  child: _buildPanel(
                    title: "M.C. FAULT CODES",
                    child: ListView(
                      children: state.mcFaults.map((f) => Text(
                        f, 
                        style: TextStyle(color: f == "NONE" ? Colors.greenAccent : Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold))
                      ).toList(),
                    )
                  )
                )
              ],
            )
          )
        ],
      )
    );
  }

  Widget _buildPanel({required String title, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: Colors.white24, width: 1),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 6),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
            child: Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          ),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}


// ---------------------------------------------------------
// WINDOW 3: HARDWARE OVERRIDES & CONFIGURATION
// ---------------------------------------------------------
class _ConfigView extends StatelessWidget {
  final DashboardState state;
  const _ConfigView({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // LEFT: HARDWARE COMMANDS
          Expanded(
            flex: 2,
            child: _buildPanel("HARDWARE COMMAND OVERRIDES", Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCmdBtn("SYNC RTC [CLOCK]", () { debugPrint("USB CAN TX: RTC SYNC"); }),
                const SizedBox(height: 8),
                _buildCmdBtn("CALIBRATE PEDAL 0-100%", () { debugPrint("USB CAN TX: PEDAL CALIBRATE"); }),
                const SizedBox(height: 16),
                const Text("AUX SIGNAL MANIPULATION", style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 10)),
                const SizedBox(height: 8),
                Row(
                   children: [
                     Expanded(child: _buildCmdBtn("LIGHTS", () { debugPrint("USB CAN TX: TOGGLE LIGHTS"); })),
                     const SizedBox(width: 4),
                     Expanded(child: _buildCmdBtn("WIPER", () { debugPrint("USB CAN TX: TOGGLE WIPER"); })),
                     const SizedBox(width: 4),
                     Expanded(child: _buildCmdBtn("HORN", () { debugPrint("USB CAN TX: TOGGLE HORN"); })),
                   ]
                )
              ]
            ))
          ),
          const SizedBox(width: 4),

          // CENTER: THROTTLE MAPPING
          Expanded(
            flex: 3,
            child: _buildPanel("THROTTLE RAMP MAPPING (0-100%)", Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(5, (index) {
                  return Column(
                    children: [
                      Text("${index * 25}% IN", style: const TextStyle(color: Colors.white54, fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 12)),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: -1, // Makes the slider vertical
                          child: Slider(
                            value: state.throttleMap[index],
                            min: 0, 
                            max: 100,
                            activeColor: Colors.orangeAccent,
                            onChanged: (val) => state.updateThrottleMap(index, val),
                          )
                        )
                      ),
                      Text("${state.throttleMap[index].toStringAsFixed(0)}% OUT", style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  );
              })
            ))
          ),
          const SizedBox(width: 4),

          // RIGHT: APP CONFIG
          Expanded(
            flex: 2,
            child: _buildPanel("SOFTWARE CONFIGURATION", Column(
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 const Text("API SERVER ENDPOINT URL", style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 10)),
                 const SizedBox(height: 8),
                 TextFormField(
                    initialValue: state.apiUrl,
                    style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 12),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Colors.black,
                      contentPadding: EdgeInsets.all(8),
                      border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    ),
                    onChanged: (val) => state.updateApiUrl(val),
                 ),
                 const Spacer(),
                 _buildCmdBtn("SAVE & RESTART SOCKETS", () { debugPrint("API Service Rebuilding with ${state.apiUrl}"); }),
               ]
            ))
          )
        ]
      )
    );
  }

  Widget _buildPanel(String title, Widget child) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.white24, width: 1)),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
            child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
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
        decoration: BoxDecoration(border: Border.all(color: Colors.white54), color: const Color(0xFF141414)),
        alignment: Alignment.center,
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      ),
    );
  }
}
