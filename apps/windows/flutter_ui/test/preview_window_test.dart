import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/preview_app.dart';

void main() {
  for (final size in [const Size(1280, 800), const Size(720, 480)]) {
    testWidgets('memory preview fits $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const PreviewApplication());
      await tester.pump();
      expect(find.text('FreeV6'), findsOneWidget);
      expect(find.text('演示模式 · 不连接网络'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
