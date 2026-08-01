import 'package:flutter/material.dart';

// =============================================================================
// Helper: theme-aware color palette
// =============================================================================
class Palette {
  final bool light;
  Palette(this.light);

  Color get bg => light ? const Color(0xFFF5F5F5) : Colors.black;
  Color get border => light ? Colors.black26 : Colors.white24;
  Color get dimText => light ? Colors.black54 : Colors.white54;
  Color get mainText => light ? Colors.black : Colors.white;
  Color get barBg => light ? Colors.grey.shade300 : Colors.transparent;

  // Softer accent colors — readable but not neon
  Color get cyan => light ? const Color(0xFF006064) : const Color(0xFF80DEEA);
  Color get green => light ? const Color(0xFF1B5E20) : const Color(0xFF81C784);
  Color get amber => light ? const Color(0xFF8F6E00) : const Color(0xFFFFD54F);
  Color get orange => light ? const Color(0xFFBF360C) : const Color(0xFFFFB74D);
  Color get red => light ? const Color(0xFFB71C1C) : const Color(0xFFEF5350);
  Color get yellow => light ? const Color(0xFF827717) : const Color(0xFFFFF176);
  Color get purple => light ? const Color(0xFF4A148C) : const Color(0xFFCE93D8);
  Color get teal => light ? const Color(0xFF004D40) : const Color(0xFF80CBC4);
  Color get pink => light ? const Color(0xFF880E4F) : const Color(0xFFF48FB1);
  Color get lightGreen =>
      light ? const Color(0xFF33691E) : const Color(0xFFA5D6A7);
  Color get deepOrange =>
      light ? const Color(0xFFBF360C) : const Color(0xFFFF8A65);
}
