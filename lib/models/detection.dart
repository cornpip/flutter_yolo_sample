import 'dart:ui';

class Detection {
  const Detection({
    required this.boundingBox,
    required this.confidence,
    required this.label,
  });

  /// Bounding box with normalized coordinates (0-1) relative to the preview.
  final Rect boundingBox;
  final double confidence;
  final String label;
}

