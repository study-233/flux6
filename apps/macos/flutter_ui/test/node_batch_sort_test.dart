import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/app_theme.dart';
import 'package:freev6_flutter_preview/components/proxy_card.dart';
import 'package:freev6_flutter_preview/live/nodes_page.dart';

import 'setup_download_test.dart' show SetupHost;

const nodes = ['Node10', 'Node2', 'Node1', 'Untested', 'Failed'];

SetupHost nodeHost() => SetupHost()
  ..change({
    'phase': 'running',
    'groups': [
      {
        'id': 'access',
        'members': nodes,
        'source': 'session',
        'current': 'Node1',
        'latencies': {'Node1': 50, 'Node2': 10, 'Node10': 'timeout'},
      },
    ],
    'download': {
      'active': false,
      'results': {
        'access': {
          'Node2': {'status': 'complete', 'bytesPerSecond': 4000000},
          'Node1': {'status': 'complete', 'bytesPerSecond': 1000000},
          'Node10': {'status': 'complete', 'bytesPerSecond': 1000000},
          'Failed': {'status': 'failed'},
        },
      },
    },
  });

Future<void> mount(
  WidgetTester tester,
  SetupHost host, {
  bool dark = false,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    FreeV6Theme(
      title: 'test',
      appearance: dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: LiveNodesPage(model: host),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> cardNames(WidgetTester tester) => tester
    .widgetList<HostProxyCard>(find.byType(HostProxyCard))
    .map((card) => card.name)
    .toList();

Future<void> orderBy(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('节点排序'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuEntry),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'natural names, speed descending, latency ascending; automatic stays first',
    (tester) async {
      final host = nodeHost();
      await mount(tester, host);
      expect(cardNames(tester), [
        '自动选择',
        'Failed',
        'Node1',
        'Node2',
        'Node10',
        'Untested',
      ]);
      await orderBy(tester, '下载速度（高 → 低）');
      expect(cardNames(tester), [
        '自动选择',
        'Node2',
        'Node1',
        'Node10',
        'Failed',
        'Untested',
      ]);
      await orderBy(tester, '延迟（低 → 高）');
      expect(cardNames(tester), [
        '自动选择',
        'Node2',
        'Node1',
        'Failed',
        'Node10',
        'Untested',
      ]);
      await orderBy(tester, '名称（A → Z）');
      expect(cardNames(tester), [
        '自动选择',
        'Failed',
        'Node1',
        'Node2',
        'Node10',
        'Untested',
      ]);
      expect(host.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      host.dispose();
    },
  );

  testWidgets(
    'batch uses the whole current group through a search; progress can stop',
    (tester) async {
      final host = nodeHost();
      await mount(tester, host);
      expect(find.textContaining('下载测速会产生真实流量'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Node1');
      await tester.pumpAndSettle();
      expect(cardNames(tester), ['Node1', 'Node10']);
      await tester.tap(find.text('整组测速'));
      await tester.pump();
      expect(host.calls.last.$1, 'download.start');
      expect(host.calls.last.$2, {'group': 'access', 'nodes': nodes});
      host.change({
        'download': {
          'active': true,
          'group': 'access',
          'node': 'Node2',
          'completed': 2,
          'total': 5,
        },
      });
      await tester.pump();
      await tester.tap(find.text('停止测速 2/5'));
      await tester.pump();
      expect(host.calls.last.$1, 'download.cancel');
      host.change({
        'download': {
          'active': true,
          'cancelling': true,
          'completed': 2,
          'total': 5,
        },
      });
      await tester.pump();
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '正在停止…'),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      host.dispose();
    },
  );

  testWidgets('live sorting preserves keyboard target identity', (
    tester,
  ) async {
    final host = nodeHost();
    await mount(tester, host);
    await orderBy(tester, '下载速度（高 → 低）');
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    String target() => tester
        .widgetList<HostProxyCard>(find.byType(HostProxyCard))
        .singleWhere((card) => card.keyboardTarget)
        .name;
    expect(target(), 'Node2');
    host.change({
      'download': {
        'active': false,
        'results': {
          'access': {
            'Node1': {'status': 'complete', 'bytesPerSecond': 8000000},
            'Node2': {'status': 'complete', 'bytesPerSecond': 4000000},
          },
        },
      },
    });
    await tester.pump();
    expect(cardNames(tester).take(3), ['自动选择', 'Node1', 'Node2']);
    expect(target(), 'Node2');
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('batch toolbar fits minimum window at 130% text, dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = nodeHost();
      await mount(tester, host, dark: dark, scale: 1.3);
      await orderBy(tester, '下载速度（高 → 低）');
      await tester.tap(find.text('整组测速'));
      await tester.pump();
      expect(host.calls.last.$1, 'download.start');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      host.dispose();
    });
  }
}
