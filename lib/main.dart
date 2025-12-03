import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import 'page/main_page.dart';
import 'page/yolo_camera_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(YoloApp(cameras: cameras));
}

class YoloApp extends StatelessWidget {
  YoloApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  late final GoRouter _router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => MainPage(cameras: cameras),
      ),
      GoRoute(
        path: '/camera',
        builder: (context, state) => YoloCameraPage(cameras: cameras),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(360, 690),
      builder: (context, child) {
        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true),
          routerConfig: _router,
        );
      },
    );
  }
}

