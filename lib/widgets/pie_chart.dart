import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/formats.dart';

/// Basit pasta grafik (ek paket yok — Bellek Analizi için).
class CategoryPieChart extends StatelessWidget {
  const CategoryPieChart({
    super.key,
    required this.slices,
    this.size = 180,
  });

  final List<PieSlice> slices;
  final double size;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<int>(0, (s, e) => s + e.bytes);
    if (total <= 0 || slices.isEmpty) {
      return SizedBox(
        height: size,
        child: const Center(child: Text('Veri yok')),
      );
    }
    return Column(
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _PiePainter(slices: slices, total: total),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final s in slices)
              if (s.bytes > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: s.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${s.label} ${Formats.size(s.bytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
          ],
        ),
      ],
    );
  }
}

class PieSlice {
  const PieSlice({
    required this.label,
    required this.bytes,
    required this.color,
  });

  final String label;
  final int bytes;
  final Color color;
}

class _PiePainter extends CustomPainter {
  _PiePainter({required this.slices, required this.total});

  final List<PieSlice> slices;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    var start = -math.pi / 2;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final s in slices) {
      if (s.bytes <= 0) continue;
      final sweep = (s.bytes / total) * 2 * math.pi;
      paint.color = s.color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        true,
        paint,
      );
      start += sweep;
    }
    // Ortada delik (donut) — yarı saydam, tema üstüne biner.
    paint.color = const Color(0xE6FFFFFF);
    canvas.drawCircle(center, radius * 0.45, paint);
    paint.color = const Color(0x33000000);
    canvas.drawCircle(center, radius * 0.45, paint);
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) =>
      oldDelegate.total != total || oldDelegate.slices != slices;
}
