import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/components/flclash.dart';
import 'package:freev6_flutter_preview/main.dart';
import 'package:freev6_flutter_preview/preview/fixture_model.dart';

void main() {
  testWidgets(
    'desktop grid aligns the hero with the mode bar and separates both directions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1232, 780);
      addTearDown(tester.view.reset);
      final model = FixtureModel.memory();
      addTearDown(model.dispose);
      await tester.pumpWidget(FreeV6Preview(model: model));
      await tester.pumpAndSettle();
      final hero = tester.getRect(find.byType(CurrentOutboundCard));
      final mode = tester.getRect(find.byType(OutboundModeBar));
      final up = tester.getRect(find.byType(SpeedCard).first);
      final down = tester.getRect(find.byType(SpeedCard).last);
      expect(hero.left, closeTo(mode.left, .01));
      expect(hero.width, closeTo(mode.width, .01));
      expect(hero.width, closeTo(up.width * 2 + 16, .05));
      expect(up.top, hero.top);
      expect(down.left, greaterThan(up.left));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scrolling past the compact connection card keeps the header action reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(720, 480);
      addTearDown(tester.view.reset);
      final model = FixtureModel.memory();
      addTearDown(model.dispose);
      await tester.pumpWidget(FreeV6Preview(model: model));
      await tester.pumpAndSettle();
      final menu = find.byTooltip('预览场景与外观');
      final initial = tester.getCenter(menu);
      await tester.dragFrom(const Offset(470, 390), const Offset(0, -335));
      await tester.pumpAndSettle();
      final headerAction = find.widgetWithText(TextButton, '断开');
      expect(tester.getCenter(menu), initial);
      expect(tester.getCenter(headerAction).dy, closeTo(initial.dy, 1));
      await tester.tap(headerAction);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(model.connected, isFalse);
      expect(find.widgetWithText(TextButton, '连接'), findsOneWidget);
    },
  );

  testWidgets(
    'compact window keeps offline mode and node selection available',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(720, 480);
      addTearDown(tester.view.reset);
      final model = FixtureModel.memory(online: false);
      addTearDown(model.dispose);
      await tester.pumpWidget(FreeV6Preview(model: model));
      await tester.pumpAndSettle();
      final hero = tester.getRect(find.byType(CurrentOutboundCard));
      final up = tester.getRect(find.byType(SpeedCard).first);
      expect(up.top, greaterThan(hero.bottom));
      expect(find.text('未连接'), findsWidgets);
      final global = find.descendant(
        of: find.byType(OutboundModeBar),
        matching: find.text('全局'),
      );
      await tester.ensureVisible(global);
      await tester.tap(global);
      await tester.pumpAndSettle();
      expect(model.mode, '全局');
      final nodeEntry = find.text('接入节点').first;
      await tester.ensureVisible(nodeEntry);
      await tester.tap(nodeEntry);
      await tester.pumpAndSettle();
      final west = find.descendant(
        of: find.byType(Dialog),
        matching: find.text('西区'),
      );
      await tester.tap(west);
      await tester.pumpAndSettle();
      expect(model.preferredNode, '西区');
      expect(model.connected, false);
      expect(tester.takeException(), isNull);
    },
  );
}
