// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child paint in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi_plugin_look/ffi_plugin_look.dart' as ffi_plugin_look;

void main() {
  testWidgets('Placeholder widget test', (WidgetTester tester) async {
    // Pump a minimal widget to ensure flutter_test setup works.
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('placeholder'),
    ));

    expect(find.text('placeholder'), findsOneWidget);
  });
}
