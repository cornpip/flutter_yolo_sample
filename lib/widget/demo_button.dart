import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class DemoItem {
  const DemoItem({
    required this.title,
    required this.subtitle,
    required this.route,
  });

  final String title;
  final String subtitle;
  final String route;
}

class DemoButton extends StatelessWidget {
  const DemoButton({
    super.key,
    required this.item,
    required this.onTap,
    required this.enabled,
  });

  final DemoItem item;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72.h,
      child: FilledButton(
        style: FilledButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.sp),
          ),
        ),
        onPressed: enabled ? onTap : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 16.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 6.h),
                  Text(
                    item.subtitle,
                    style: TextStyle(fontSize: 13.sp, color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
