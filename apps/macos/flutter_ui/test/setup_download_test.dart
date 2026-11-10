import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/app_theme.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';
import 'package:freev6_flutter_preview/live/nodes_page.dart';
import 'package:freev6_flutter_preview/live/pages.dart';

class SetupHost extends LiveModel {
  final calls = <(String, StateMap)>[];
  SetupHost() {
    state = {
      'phase': 'idle', 'service': 'missing',
      'settings': {'accepted': true, 'setupCompleted': false},
      'setup': {'step': 0, 'active': false, 'status': '', 'error': ''},
      'groups': [{'id': 'access', 'members': ['测试节点'], 'source': 'session', 'current': '测试节点'}],
      'capabilities': {'download': true, 'measure': true},
    };
  }
  void change(StateMap fields) { state.addAll(fields); notifyListeners(); }
  @override
  Future<StateMap> command(String name, [StateMap arguments = const {}]) async {
    calls.add((name, arguments));
    return {};
  }
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('setup keeps actions visible at minimum size, dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(720, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = SetupHost();
      await tester.pumpWidget(FreeV6Theme(title: 'test', appearance: dark ? ThemeMode.dark : ThemeMode.light,
        home: Scaffold(body: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(1.3)), child: LivePreparationPage(model: host)))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始配置'));
      expect(host.calls.last.$1, 'setup.start');
      host.change({'setup': {'step': 2, 'active': true, 'status': '正在下载规则数据'}});
      await tester.pump();
      await tester.tap(find.text('暂停配置'));
      expect(host.calls.last.$1, 'setup.cancel');
      host.change({'setup': {'step': 2, 'active': false, 'error': '下载暂时失败，可继续'}});
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续配置'));
      expect(host.calls.last.$1, 'setup.start');
      host.change({'setup': {'step': 5, 'active': false, 'status': '配置检查通过'}});
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成并连接'));
      await tester.pump();
      expect(host.calls.map((e) => e.$1).toList().sublist(host.calls.length - 2), ['setup.finish', 'connect']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      host.dispose();
    });
  }

  testWidgets('node download has separate action, cancellation and MB/s result', (tester) async {
    final host = SetupHost()..change({'phase': 'running'});
    await tester.pumpWidget(FreeV6Theme(title: 'test', home: Scaffold(body: LiveNodesPage(model: host))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('测试测试节点下载速度'));
    await tester.pump();
    expect(host.calls.last.$1, 'download.start');
    expect(host.calls.last.$2, {'group': 'access', 'node': '测试节点'});
    expect(host.calls.any((c) => c.$1 == 'setNode'), isFalse);
    host.change({'download': {'active': true, 'group': 'access', 'node': '测试节点'}});
    await tester.pump();
    await tester.tap(find.byTooltip('取消测试节点下载测速'));
    await tester.pump();
    expect(host.calls.last.$1, 'download.cancel');
    host.change({'download': {'active': false, 'results': {'access': {'测试节点': {'status': 'complete', 'bytesPerSecond': 2500000, 'time': '2026-11-10T00:00:00Z', 'bytes': 5000000}}}}});
    await tester.pumpAndSettle();
    expect(find.text('2.50 MB/s'), findsOneWidget);
    expect(find.text('整组测延迟'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });
}
