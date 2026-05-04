import 'package:flutter/material.dart';

// =============================================================================
// Helper: theme-aware color palette
// =============================================================================
class Palette {
  final bool light;
  Palette(this.light);

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
