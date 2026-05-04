import 'dart:math';
import 'package:flutter/material.dart';
import 'package:telemetry_dashboard/core/theme/palette.dart';
// =============================================================================
// Rolling Graph Custom Painter
// =============================================================================
class GraphPainter extends CustomPainter {
  final List<double> data;
  final Palette p;
  GraphPainter(this.data, this.p);

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
  bool shouldRepaint(covariant GraphPainter old) => true;
}

class ThrottleMapPainter extends CustomPainter {
  final Palette p;
  final List<double> values;

  ThrottleMapPainter({required this.p, required this.values});

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
  bool shouldRepaint(covariant ThrottleMapPainter oldDelegate) {
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



