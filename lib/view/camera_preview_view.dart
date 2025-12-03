import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:yolo/models/detection.dart';
import 'package:yolo/paint/detection_painter.dart';

class CameraPreviewView extends StatelessWidget {
  const CameraPreviewView({
    super.key,
    required this.controller,
    required this.detections,
    required this.statusChip,
    required this.controls,
    required this.isCameraAvailable,
  });

  final CameraController? controller;
  final List<Detection> detections;
  final Widget statusChip;
  final Widget controls;
  final bool isCameraAvailable;

  @override
  Widget build(BuildContext context) {
    final previewSize = controller?.value.previewSize;
    final previewSizeText = previewSize != null
        ? '${previewSize.width.toStringAsFixed(0)} x ${previewSize.height.toStringAsFixed(0)}'
        : 'Unknown';
    final aspectRatio =
        controller != null && controller!.value.aspectRatio != 0
            ? controller!.value.aspectRatio
            : (4 / 3);
    final isBackCamera =
        controller?.description.lensDirection == CameraLensDirection.back;
    final borderRadius = BorderRadius.circular(20.r);
    final innerRadius = BorderRadius.circular(18.r);
    final previewWidth = 300.w;
    final previewHeight = previewWidth * 4 / 3;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration:
                  BoxDecoration(color: Colors.black54, borderRadius: borderRadius),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRRect(
                  borderRadius: innerRadius,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: previewWidth,
                        height: previewHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (isCameraAvailable && controller != null)
                              ClipRRect(
                                borderRadius: borderRadius,
                                child: Transform(
                                  alignment: Alignment.center,
                                  transform: isBackCamera
                                      ? Matrix4.identity()
                                      : (Matrix4.identity()
                                        ..rotateY(math.pi)),
                                  child: CameraPreview(controller!),
                                ),
                              )
                            else
                              AspectRatio(
                                aspectRatio: 1 / aspectRatio,
                                child: Container(
                                  color: Colors.black26,
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'Camera is initializing...',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                              ),
                            if (isCameraAvailable && controller != null)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: DetectionPainter(
                                      detections: detections),
                                ),
                              ),
                            Positioned(
                              left: 16,
                              bottom: 16,
                              child: statusChip,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: 0),
          child: Text(
            'Model: YOLOv11-nano • Detections: ${detections.length}\nImage size: $previewSizeText',
            style: const TextStyle(color: Colors.black),
            textAlign: TextAlign.center,
          ),
        ),
        controls,
      ],
    );
  }
}
