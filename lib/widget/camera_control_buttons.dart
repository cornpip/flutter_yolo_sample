import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class CameraControlButtons extends StatelessWidget {
  const CameraControlButtons({
    super.key,
    required this.isCameraActive,
    required this.isDetectionActive,
    required this.isControllerReady,
    required this.isCameraBusy,
    required this.isChangingCamera,
    required this.camerasLength,
    required this.onToggleCamera,
    required this.onToggleDetection,
    required this.onSwitchCamera,
  });

  final bool isCameraActive;
  final bool isDetectionActive;
  final bool isControllerReady;
  final bool isCameraBusy;
  final bool isChangingCamera;
  final int camerasLength;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleDetection;
  final VoidCallback onSwitchCamera;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isCameraBusy ? null : onToggleCamera,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isCameraActive ? Colors.redAccent : Colors.greenAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: Icon(
                    isCameraActive ? Icons.stop : Icons.camera,
                    color: Colors.black,
                  ),
                  label: Text(isCameraActive ? 'Stop Capture' : 'Start Capture'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (!isCameraActive ||
                          !isControllerReady ||
                          isCameraBusy)
                      ? null
                      : onToggleDetection,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDetectionActive
                        ? Colors.orangeAccent
                        : Colors.blueAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: Icon(
                    isDetectionActive
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: Colors.black,
                  ),
                  label:
                      Text(isDetectionActive ? 'Stop Detection' : 'Start Detection'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: (camerasLength < 2 || isChangingCamera || isCameraBusy)
                ? null
                : onSwitchCamera,
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 16.h),
            ),
            icon: const Icon(Icons.cameraswitch),
            label: const Text('Switch Camera'),
          ),
        ],
      ),
    );
  }
}
