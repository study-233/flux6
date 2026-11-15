import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/client_app.dart';
import 'package:freev6_windows/app/desktop_chrome.dart';
import 'package:freev6_windows/app/preview_model.dart';
import 'package:prism_ui/tooltip.dart' as prism;

void main() {
  testWidgets('node search clears when locating the current node', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = PreviewModel();
    addTearDown(model.dispose);
    await tester.runAsync(model.toggleConnection);
    await tester.pumpWidget(ClientApplication(model: model));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final search = find.widgetWithText(TextField, '搜索节点');
    await tester.enterText(search, '西区');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('node:东区 · IPv6')), findsNothing);
    await tester.tap(find.byTooltip('定位当前节点'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('node:东区 · IPv6')), findsOneWidget);
    expect(find.byKey(const ValueKey('node:西区 · IPv6')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'sidebar reserves content space after resizing and overlay navigation works',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final model = PreviewModel();
      addTearDown(model.dispose);
      await tester.pumpWidget(ClientApplication(model: model));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('desktop-sidebar'))).width,
        220,
      );
      tester.view.physicalSize = const Size(720, 480);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('desktop-sidebar'))).width,
        78,
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is prism.Tooltip && widget.message == '展开',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DesktopSidebar).last,
          matching: find.text('配置'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '订阅地址'), findsOneWidget);
      expect(find.byType(DesktopSidebar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'settings categories expose appearance and data without a long scroll',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final model = PreviewModel();
      addTearDown(model.dispose);
      await tester.pumpWidget(ClientApplication(model: model));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外观').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('跟随系统'), findsOneWidget);
      await tester.tap(find.text('数据').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('导出界面备份'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
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
