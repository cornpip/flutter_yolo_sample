import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/detection.dart';

class DetectionPainter extends CustomPainter {
  DetectionPainter({
    required this.detections,
  });

  final List<Detection> detections;

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.lightGreenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (final detection in detections) {
      final rect = Rect.fromLTRB(
        detection.boundingBox.left * size.width,
        detection.boundingBox.top * size.height,
        detection.boundingBox.right * size.width,
        detection.boundingBox.bottom * size.height,
      );
      canvas.drawRect(rect, boxPaint);

      final label = '${detection.label} ${(detection.confidence * 100).toStringAsFixed(1)}%';
      final textSpan = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final textBackground = Rect.fromLTWH(
        rect.left,
        math.max(0, rect.top - textPainter.height - 4),
        textPainter.width + 8,
        textPainter.height + 4,
      );

      final backgroundPaint = Paint()
        ..color = Colors.lightGreenAccent.withOpacity(0.85)
        ..style = PaintingStyle.fill;
      canvas.drawRect(textBackground, backgroundPaint);
      textPainter.paint(
        canvas,
        Offset(textBackground.left + 4, textBackground.top + 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter oldDelegate) {
    return oldDelegate.detections != detections;
  }
}
