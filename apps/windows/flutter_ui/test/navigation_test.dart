import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/client_app.dart';
import 'package:freev6_windows/app/preview_model.dart';

void main() {
  testWidgets(
    'keyboard navigation preserves configuration draft and validates URL',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = PreviewModel();
      addTearDown(model.dispose);
      await tester.pumpWidget(ClientApplication(model: model));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '订阅地址'), 'invalid');
      await tester.tap(find.text('导入订阅'));
      await tester.pumpAndSettle();
      expect(find.text('请输入完整的 HTTP 或 HTTPS 订阅地址'), findsOneWidget);
      expect(model.chain['count'], 0);
      await tester.enterText(
        find.widgetWithText(TextField, '订阅地址'),
        'https://example.invalid/synthetic',
      );
      await tester.tap(find.text('导入订阅'));
      await tester.pumpAndSettle();
      expect(model.chain['count'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'settings retain Windows controls and hide direct mode by default',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = PreviewModel();
      addTearDown(model.dispose);
      await tester.pumpWidget(ClientApplication(model: model));
      expect(find.text('直连'), findsNothing);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('F6 快捷键'), findsOneWidget);
      expect(find.text('共享移动热点'), findsOneWidget);
      await tester.tap(find.text('F6 快捷键'));
      await tester.pumpAndSettle();
      expect(model.setting('hotkeyEnabled'), true);
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
