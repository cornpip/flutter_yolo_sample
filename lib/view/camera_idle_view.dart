import 'package:flutter/material.dart';

class CameraIdleView extends StatelessWidget {
  const CameraIdleView({super.key, required this.controls});

  final Widget controls;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Expanded(
          child: Center(
            child: Text(
              'Tap the capture button to start the camera.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
        controls,
      ],
    );
  }
}
