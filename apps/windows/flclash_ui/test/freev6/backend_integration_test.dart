import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/freev6/application.dart';
import 'package:fl_clash/freev6/forms.dart';
import 'package:fl_clash/freev6/navigation.dart';
import 'package:fl_clash/freev6/offline_fixture.dart';
import 'package:fl_clash/freev6/session.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/backend/api.dart' show WireReply;
import 'package:prism_ui/tooltip.dart' as prism;
import 'package:mocktail/mocktail.dart' as mocks;

class RecordingWindow extends mocks.Fake implements WindowPort {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }
}

Future<(FreeV6OfflineFixture, FreeV6Session)> fixture() async {
  final f = FreeV6OfflineFixture(polling: false);
  await f.model.initialize();
  final s = FreeV6Session(f.model, backend: true);
  addTearDown(() {
    s.dispose();
    f.host.dispose();
  });
  return (f, s);
}

void main() {
  test(
    'a group switch cancels an old batch without waiting for its network replies',
    () async {
      final (f, s) = await fixture();
      await s.act('chain.import', {
        'url': 'https://example.invalid/chain.yaml',
      });
      await s.container.read(setupActionProvider.notifier).setRunning(true);
      final started = Completer<void>();
      final reply = Completer<WireReply>();
      f.transport.intercept = (r) async {
        if (r.uri.pathSegments.last != 'delay') return null;
        if (!started.isCompleted) started.complete();
        return reply.future;
      };
      final action = s.container.read(proxiesActionProvider.notifier);
      final batch = action.delayTest([]);
      await started.future;
      expect(s.container.read(pendingDelayTestsProvider), isNotEmpty);
      try {
        await action
            .changeProxy(groupName: chainGroup, proxyName: '链式 · B')
            .timeout(const Duration(seconds: 2));
        expect(f.model.proxyTab, 'chain');
        expect(f.model.currentNode, '链式 · B');
      } finally {
        reply.complete(const WireReply(200, '{"delay":1}'));
        await batch;
      }
      expect(f.model.latency('东区 / IPv6'), null);
      expect(s.container.read(pendingDelayTestsProvider), isEmpty);
      await s.act('chain.clear');
      expect(f.model.proxyTab, 'access');
      expect(s.container.read(groupsProvider).length, 1);
    },
  );
  test(
    'close goes through the native host so tray failure can keep the window reachable',
    () async {
      final f = FreeV6OfflineFixture(polling: false);
      await f.model.initialize();
      final s = FreeV6Session(f.model, backend: true, offline: false);
      final port = RecordingWindow();
      windowPort = port;
      try {
        await s.container.read(systemActionProvider.notifier).handleClose();
        expect(port.closes, 1);
        expect(f.host.quitRequested, false);
      } finally {
        windowPort = null;
        s.dispose();
        f.host.dispose();
      }
    },
  );
  test(
    'backend entry is explicit; the offline fixture accepts only known requests',
    () async {
      final f = FreeV6OfflineFixture(polling: false);
      expect(() => FreeV6Session(f.model), throwsArgumentError);
      await expectLater(
        f.transport.send('GET', Uri.parse('https://example.com')),
        throwsStateError,
      );
      final unauthorized = await f.transport.send(
        'GET',
        Uri.parse('http://127.0.0.1:18213/api/v1/status'),
      );
      expect(unauthorized.status, 401);
      await expectLater(f.host.call('process.start'), throwsStateError);
      f.model.dispose();
      f.host.dispose();
    },
  );

  test(
    'the upstream start/mode/node/traffic/stop path uses real FreeV6 backend credentials',
    () async {
      final (f, s) = await fixture();
      final setup = s.container.read(setupActionProvider.notifier);
      expect(await setup.setRunning(true), true);
      expect(
        f.transport.requests.any(
          (r) => r.uri.toString() == 'https://api-ipv6.ip.sb/ip',
        ),
        true,
      );
      await s.container
          .read(proxiesActionProvider.notifier)
          .changeProxy(groupName: accessGroup, proxyName: '西区 · IPv6');
      expect(f.model.currentNode, '西区 · IPv6');
      setup.changeMode(Mode.direct);
      expect(f.model.mode, '规则');
      expect(
        await s.act('settings.save', {'mode': 'global', 'hotspotShare': true}),
        true,
      );
      await f.model.pollTraffic();
      await f.model.pollTraffic();
      expect(f.model.usageDownload, greaterThan(0));
      expect(
        s.container.read(totalTrafficProvider).down,
        f.model.usageDownload,
      );
      expect(await setup.setRunning(false), true);
      expect(
        s.container.read(logsProvider).list.last.payload,
        f.model.logs.first.message,
      );
      final helperRequests = f.transport.requests.where(
        (r) => r.uri.port == 18213,
      );
      expect(
        helperRequests.every(
          (r) => r.headers['Authorization'] == 'Bearer offline-fixture-token',
        ),
        true,
      );
      expect(
        f.transport.requests
            .where((r) => r.uri.port == 9090)
            .every(
              (r) =>
                  r.headers['Authorization'] ==
                  'Bearer offline-controller-token',
            ),
        true,
      );
      expect(s.blockedCoreCalls, isEmpty);
    },
  );

  test(
    'missing runtime and campus IPv6 failures never reach proxy start',
    () async {
      final (f, s) = await fixture();
      f.transport.present = false;
      await s.act('refresh');
      expect(
        await s.container.read(setupActionProvider.notifier).setRunning(true),
        false,
      );
      expect(f.model.message, contains('缺少运行核心'));
      expect(await s.act('core.download'), true);
      f.transport.campusAddress = '2001:db8::1';
      expect(
        await s.container.read(setupActionProvider.notifier).setRunning(true),
        false,
      );
      expect(f.model.message, contains('教育网 IPv6'));
      expect(
        f.transport.requests.where((r) => r.uri.path == '/api/v1/proxy/start'),
        isEmpty,
      );
      f.transport.campusAddress = '2001:da8::1';
      f.transport.registered = false;
      await s.act('refresh');
      expect(
        await s.container.read(setupActionProvider.notifier).setRunning(true),
        true,
      );
      expect(
        f.transport.requests.any((r) => r.uri.path == '/api/v1/warp/register'),
        true,
      );
    },
  );

  test(
    'group changes serialize before selection and retain separate visible nodes',
    () async {
      final (f, s) = await fixture();
      await s.act('chain.import', {
        'url': 'https://example.invalid/chain.yaml',
      });
      await s.container.read(setupActionProvider.notifier).setRunning(true);
      final proxies = s.container.read(proxiesActionProvider.notifier);
      proxies.updateCurrentGroupName(chainGroup);
      await proxies.changeProxy(groupName: chainGroup, proxyName: '链式 · B');
      expect(f.model.proxyTab, 'chain');
      expect(f.model.currentNode, '链式 · B');
      final write = f.transport.requests.lastWhere(
        (r) => r.method == 'PUT' && r.uri.port == 9090,
      );
      expect(write.uri.pathSegments, ['proxies', '🔗 链式代理']);
      expect(write.body['name'], '链式 · B');
      final groups = s.container.read(groupsProvider);
      expect(groups.first.all.map((p) => p.name), contains('东区 / IPv6'));
      expect(groups.last.all.map((p) => p.name), contains('链式 · B'));
      await proxies.changeProxy(groupName: accessGroup, proxyName: '东区 / IPv6');
      expect(f.model.proxyTab, 'access');
      expect(s.blockedCoreCalls, isEmpty);
    },
  );

  test('batch delay tests retain the backend six-request limit', () async {
    final (f, s) = await fixture();
    f.transport.nodes.addAll(List.generate(13, (i) => '接入点 / $i'));
    await s.container.read(setupActionProvider.notifier).setRunning(true);
    var active = 0, maximum = 0;
    f.transport.intercept = (r) async {
      if (r.uri.pathSegments.last != 'delay') return null;
      active++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
      return const WireReply(200, '{"delay":36}');
    };
    await s.container.read(proxiesActionProvider.notifier).delayTest([]);
    expect(maximum, inInclusiveRange(2, 6));
    expect(f.model.nodes.every((n) => f.model.latency(n) == 36), true);
  });

  test(
    'F6 registration and save failures preserve settings and roll back the host',
    () async {
      final (f, s) = await fixture();
      f.host.hotkeyFails = true;
      expect(await s.act('settings.save', {'hotkeyEnabled': true}), false);
      expect(f.model.setting('hotkeyEnabled'), false);
      f.host.hotkeyFails = false;
      f.transport.saveFails = true;
      expect(await s.act('settings.save', {'hotkeyEnabled': true}), false);
      expect(
        f.host.calls.where((c) => c.$1 == 'hotkey').last.$2['enabled'],
        false,
      );
      expect(f.model.setting('hotkeyEnabled'), false);
      f.transport.saveFails = false;
      expect(
        await s.act('settings.save', {
          'autoStart': true,
          'silentStart': true,
          'autoRunProxy': true,
          'hotkeyEnabled': true,
        }),
        true,
      );
      expect(f.model.setting('autoStart'), true);
      expect(f.model.setting('hotkeyEnabled'), true);
    },
  );

  test(
    'cloud announcement gate, registration and progress failures remain visible',
    () async {
      final (f, s) = await fixture();
      f.transport.cloudLocked = true;
      await s.act('refresh');
      expect(
        await s.act('cloud.import', {'portalHost': 'portal.example.invalid'}),
        false,
      );
      expect(f.model.cloud['count'], 0);
      expect(f.model.message, contains('公告'));
      f.transport.cloudLocked = false;
      expect(
        await s.act('cloud.import', {'portalHost': 'portal.example.invalid'}),
        true,
      );
      expect(f.model.cloud['portalHost'], 'portal.example.invalid');
      f.transport.intercept = (r) async =>
          r.uri.path.endsWith('/runtime/download/progress')
          ? const WireReply(
              200,
              '{"state":"error","error":"fixture download failed"}',
            )
          : null;
      expect(await s.act('core.download'), false);
      expect(f.model.message, contains('fixture download failed'));
      f.transport.intercept = null;
      expect(await s.act('core.download'), true);
      expect(f.model.coreDownload['state'], 'done');
    },
  );

  test(
    'quit and update cannot bypass a failed stop; installer remains a fixture call',
    () async {
      final (f, s) = await fixture();
      await s.container.read(setupActionProvider.notifier).setRunning(true);
      f.transport.stopFails = true;
      await s.container.read(systemActionProvider.notifier).handleExit();
      expect(f.host.quitRequested, false);
      expect(f.model.connected, true);
      await s.act('update.check');
      expect(await s.act('update.install'), false);
      expect(f.host.updateRequested, false);
      f.transport.stopFails = false;
      expect(await s.act('update.install'), true);
      expect(f.host.updateRequested, true);
      expect(f.model.connected, false);
      expect(f.host.calls.last.$1, 'update.apply');
      await s.act('update.skip');
      expect(f.model.preference('freev6-skip-version'), '0.5.4');
      expect(s.blockedCoreCalls, isEmpty);
    },
  );

  test(
    'helper exit disables connection until the authenticated refresh recovers',
    () async {
      final (f, s) = await fixture();
      f.host.stream.add('helperExited');
      await Future<void>.delayed(Duration.zero);
      expect(f.model.canConnectAction, false);
      expect(s.container.read(coreStatusProvider), CoreStatus.disconnected);
      expect(await s.act('refresh'), true);
      expect(f.model.canConnectAction, true);
      expect(f.host.calls.any((c) => c.$1 == 'bootstrap'), true);
    },
  );

  test(
    'preference migration, wallpaper and logs use isolated files and the existing validator',
    () async {
      final (f, s) = await fixture();
      final dir = await Directory.systemTemp.createTemp(
        'freev6-backend-fixture-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final input = File('${dir.path}/preferences.json');
      await input.writeAsString(
        jsonEncode({
          'format': 'freev6-ui-preferences',
          'version': 1,
          'values': {'freev6-theme': 'dark', 'freev6-pure-black': '1'},
        }),
      );
      f.host.selectedFile = input.path;
      expect(await s.act('preferences.import'), true);
      expect(f.model.preference('freev6-theme'), 'dark');
      expect(s.container.read(themeSettingProvider).pureBlack, true);
      final png = File('${dir.path}/wallpaper.png');
      await png.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
        ),
      );
      f.host.selectedFile = png.path;
      expect(await s.act('wallpaper.choose'), true);
      expect(f.model.preference('freev6-bg-mode'), 'wallpaper');
      expect(await s.act('wallpaper.clear'), true);
      expect(f.model.preference('freev6-bg-mode'), 'default');

      final output = File('${dir.path}/output.json');
      f.host.selectedFile = output.path;
      expect(await s.act('preferences.export'), true);
      expect(
        jsonDecode(await output.readAsString())['values']['freev6-theme'],
        'dark',
      );
      final yaml = File('${dir.path}/chain.yaml');
      await yaml.writeAsString('proxies: []\n');
      f.host.selectedFile = yaml.path;
      expect(await s.act('chain.file'), true);
      expect(
        f.transport.requests
            .lastWhere(
              (r) => r.method == 'PUT' && r.uri.path.endsWith('/chain-proxy'),
            )
            .body['content'],
        'proxies: []\n',
      );
      final log = File('${dir.path}/freev6.log');
      f.host.selectedFile = log.path;
      expect(await s.container.read(logsProvider.notifier).exportLogs(), true);
      expect(await log.readAsString(), contains('本地组件已连接'));
      expect(
        await log.readAsString(),
        isNot(contains('offline-fixture-token')),
      );
      f.host.selectedFile = null;
      expect(await s.act('preferences.import'), false);
    },
  );

  testWidgets(
    'the accepted UI starts the real backend and retains a rejected configuration draft',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window'),
            (call) async => call.method.startsWith('is') ? false : null,
          );
      final (f, s) = await fixture();
      navigationPort = FreeV6Navigation();
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: s.container,
            child: const FreeV6Prototype(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .byWidgetPredicate((w) => w is prism.Tooltip && w.message == '启动')
              .last,
        );
        await tester.pumpAndSettle();
        expect(f.model.connected, true);
        s.container
            .read(currentPageLabelProvider.notifier)
            .toPage(PageLabel.profiles);
        await tester.pumpAndSettle();
        await tester.tap(find.text('直连域名与 CIDR'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(EditableText).last,
          'edu.cn, 10.0.0.0/8',
        );
        f.transport.saveFails = true;
        await tester.tap(find.text('确定').last);
        await tester.pumpAndSettle();
        expect(find.byType(FreeV6InputDialog), findsOneWidget);
        expect(find.text('edu.cn, 10.0.0.0/8'), findsOneWidget);
        expect(f.model.settings['campusCidrs'], ['edu.cn']);
        f.transport.saveFails = false;
        await tester.tap(find.text('确定').last);
        await tester.pumpAndSettle();
        expect(find.byType(FreeV6InputDialog), findsNothing);
        expect(f.model.settings['campusCidrs'], ['edu.cn', '10.0.0.0/8']);
        expect(s.blockedCoreCalls, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        navigationPort = null;
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
