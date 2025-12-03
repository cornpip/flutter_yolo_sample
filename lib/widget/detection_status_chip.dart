import 'package:flutter/material.dart';

class DetectionStatusChip extends StatelessWidget {
  const DetectionStatusChip({
    super.key,
    required this.detectionCount,
    required this.isDetectionActive,
  });

  final int detectionCount;
  final bool isDetectionActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.camera_alt, color: Colors.white70, size: 16),
          const SizedBox(width: 6),
          Text(
            isDetectionActive ? '$detectionCount objects' : 'Detection idle',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
