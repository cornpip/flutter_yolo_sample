import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';
import 'package:yolo/common/colors.dart';
import 'package:yolo/widget/demo_button.dart';

class MainPage extends StatelessWidget {
  const MainPage({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    final hasCamera = cameras.isNotEmpty;
    final demoItems = [
      const DemoItem(
        title: 'YOLOv11n realtime',
        subtitle: 'Detect objects with the camera',
        route: '/camera',
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        elevation: 0,
        backgroundColor: DEFAULT_BG,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Model Select",
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            // border: Border.all(color: Colors.blue, width: 2),
            // borderRadius: BorderRadius.circular(12),
            color: DEFAULT_BG
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.w),
            child: ListView.separated(
              itemBuilder: (context, index) {
                final item = demoItems[index];
                return Padding(
                  padding: EdgeInsets.only(top: 15.w),
                  child: DemoButton(
                    item: item,
                    enabled: hasCamera,
                    onTap: () => context.push(item.route),
                  ),
                );
              },
              separatorBuilder: (_, __) => SizedBox(height: 16.h),
              itemCount: demoItems.length,
            ),
          ),
        ),
      ),
    );
  }
}
