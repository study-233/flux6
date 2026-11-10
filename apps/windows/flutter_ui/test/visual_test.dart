import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/client_app.dart';
import 'package:freev6_windows/app/preview_model.dart';

void main() {
  const output = String.fromEnvironment('FREEV6_SNAPSHOTS');
  const fontPath = String.fromEnvironment('FREEV6_TEST_FONT');
  setUpAll(() async {
    if (fontPath.isNotEmpty) {
      for (final family in ['Roboto', 'Ahem', 'Segoe UI', '.SF UI Text']) {
        final loader = FontLoader(family)..addFont(File(fontPath).readAsBytes().then((v) => ByteData.sublistView(v)));
        await loader.load();
      }
      const icons = String.fromEnvironment('FREEV6_TEST_ICON_FONT');
      if (icons.isNotEmpty) {
        final loader = FontLoader('MaterialIcons')..addFont(File(icons).readAsBytes().then((v) => ByteData.sublistView(v)));
        await loader.load();
      }
    }
  });
  for (final dark in [false, true]) {
    testWidgets('all pages and settings fit ${dark ? 'dark compact' : 'light wide'} window', (tester) async {
      tester.view.physicalSize = dark ? const Size(720, 600) : const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = dark ? 1.3 : 1;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final m = PreviewModel();
      m.preferences['freev6-theme'] = dark ? 'dark' : 'light';
      m.preferences['reduce-motion'] = '1';
      addTearDown(m.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: boundary, child: ClientApplication(model: m)));
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        if (output.isEmpty) return;
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File('$output/${dark ? 'dark' : 'light'}-$name.png').writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await capture('dashboard');
      for (final key in [LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4].indexed) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key.$2);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        await capture('page-${key.$1 + 1}');
      }
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await capture('settings');
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
}
