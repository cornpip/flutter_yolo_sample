import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'yolo_camera_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(YoloApp(cameras: cameras));
}

class YoloApp extends StatelessWidget {
  const YoloApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YOLO sample',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.greenAccent),
        useMaterial3: true,
      ),
      home: YoloCameraPage(cameras: cameras),
    );
  }
}

