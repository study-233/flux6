import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/freev6/offline_main.dart';
import 'package:fl_clash/freev6/pages.dart';
import 'package:fl_clash/freev6/navigation.dart';
import 'package:fl_clash/freev6/session.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;
import 'package:prism_ui/tooltip.dart' as prism;

void main() {
  setUpAll(() async {
    const font = String.fromEnvironment('FREEV6_TEST_FONT');
    if (font.isNotEmpty) {
      for (final family in [
        'Ahem',
        'Roboto',
        'Segoe UI Variable Text',
        'Segoe UI',
        'Microsoft YaHei',
        'Microsoft YaHei UI',
        '.SF UI Text',
        '.SF Pro Text',
      ]) {
        final loader = FontLoader(family)
          ..addFont(File(font).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    }
  });
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window'),
          (call) async => call.method.startsWith('is') ? false : null,
        );
    navigationPort = FreeV6Navigation();
  });
  tearDown(() {
    navigationPort = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test('offline guards reject HTTP and upstream process lifecycle', () async {
    final before = OfflineHttpGuard.attempts;
    expect(
      () => HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        OfflineHttpGuard(),
      ),
      throwsStateError,
    );
    expect(OfflineHttpGuard.attempts, before + 1);
    final blocked = <String>[];
    await expectLater(GuardedCore(blocked).start(), throwsStateError);
    expect(blocked, ['start']);
  });

  test('upstream actions update the existing FreeV6 model only', () async {
    final session = FreeV6Session(OfflineFreeV6Model());
    addTearDown(session.dispose);
    expect(
      await session.container
          .read(setupActionProvider.notifier)
          .setRunning(true),
      true,
    );
    expect(session.model.connected, true);
    await session.container
        .read(proxiesActionProvider.notifier)
        .changeProxy(groupName: accessGroup, proxyName: '西区 · IPv6');
    expect(session.model.preferredNode, '西区 · IPv6');
    await session.act('settings.save', {'hotkeyEnabled': true});
    expect(session.model.setting('hotkeyEnabled'), true);
    session.container
        .read(setupActionProvider.notifier)
        .changeMode(Mode.direct);
    expect(session.model.mode, '规则');
    expect(
      session.commands,
      containsAll(['proxy.start', 'node.select', 'settings.save']),
    );
    expect(session.blockedCoreCalls, isEmpty);
  });

  for (final (dark, compact) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'full upstream application fits ${dark ? 'dark' : 'light'} ${compact ? 'compact' : 'wide'}',
      (tester) async {
        tester.view.physicalSize = compact
            ? const Size(720, 480)
            : const Size(1280, 860);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final shadows = debugDisableShadows;
        debugDisableShadows = false;
        final session = FreeV6Session(OfflineFreeV6Model());
        session.container
            .read(themeSettingProvider.notifier)
            .update(
              (p) => p.copyWith(
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              ),
            );
        final boundary = GlobalKey();
        try {
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: UncontrolledProviderScope(
                container: session.container,
                child: const FreeV6Prototype(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(HomePage), findsOneWidget);
          for (final page in [
            PageLabel.dashboard,
            PageLabel.proxies,
            PageLabel.profiles,
            PageLabel.logs,
            PageLabel.tools,
          ]) {
            session.container
                .read(currentPageLabelProvider.notifier)
                .toPage(page);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (page == PageLabel.proxies) {
              expect(find.text('东区 · IPv6'), findsWidgets);
            }
            const output = String.fromEnvironment('FREEV6_SNAPSHOTS');
            if (output.isNotEmpty) {
              await tester.runAsync(() async {
                final frame =
                    await (boundary.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                final data = await frame.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(output).create(recursive: true);
                await File(
                  '$output/${dark ? 'dark' : 'light'}-${compact ? 'compact' : 'wide'}-${page.name}.png',
                ).writeAsBytes(data!.buffer.asUint8List());
                frame.dispose();
              });
            }
          }
          for (final (title, type) in [
            ('启动与窗口', FreeV6GeneralView),
            ('外观', FreeV6AppearanceView),
            ('核心与 WARP', FreeV6AccessView),
            ('数据与维护', FreeV6DataView),
          ]) {
            await tester.tap(find.text(title));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            Navigator.of(tester.element(find.byType(type))).pop();
            await tester.pumpAndSettle();
          }
          expect(session.blockedCoreCalls, isEmpty);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDisableShadows = shadows;
          debugDefaultTargetPlatformOverride = null;
          session.dispose();
        }
      },
    );
  }

  testWidgets('the original start button and node card call the FreeV6 model', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = FreeV6Session(OfflineFreeV6Model());
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: session.container,
          child: const FreeV6Prototype(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .byWidgetPredicate(
              (widget) => widget is prism.Tooltip && widget.message == '启动',
            )
            .last,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(session.model.connected, true);
      session.container
          .read(currentPageLabelProvider.notifier)
          .toPage(PageLabel.proxies);
      await tester.pumpAndSettle();
      await tester.tap(find.text('西区 · IPv6').last);
      await tester.pumpAndSettle();
      expect(session.model.preferredNode, '西区 · IPv6');
      expect(session.commands, containsAll(['proxy.start', 'node.select']));
      expect(session.blockedCoreCalls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      session.dispose();
    }
  });

  testWidgets('long node lists fit a compact window with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = FreeV6Session(_LongNodeModel());
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: session.container,
          child: const FreeV6Prototype(),
        ),
      );
      await tester.pumpAndSettle();
      session.container
          .read(currentPageLabelProvider.notifier)
          .toPage(PageLabel.proxies);
      await tester.pumpAndSettle();
      expect(find.text(session.model.nodes.first), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(session.blockedCoreCalls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      session.dispose();
    }
  });

  testWidgets('settings open the F6 control and retain its in-memory value', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = FreeV6Session(OfflineFreeV6Model());
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: session.container,
          child: const FreeV6Prototype(),
        ),
      );
      await tester.pumpAndSettle();
      session.container
          .read(currentPageLabelProvider.notifier)
          .toPage(PageLabel.tools);
      await tester.pumpAndSettle();
      await tester.tap(find.text('启动与窗口'));
      await tester.pumpAndSettle();
      expect(find.byType(FreeV6GeneralView), findsOneWidget);
      await tester.tap(find.text('F6 快捷键'));
      await tester.pumpAndSettle();
      expect(session.model.setting('hotkeyEnabled'), true);
      expect(session.blockedCoreCalls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      session.dispose();
    }
  });
}

class _LongNodeModel extends OfflineFreeV6Model {
  @override
  List<String> get nodes =>
      List.generate(96, (i) => '校园 IPv6 / 第 ${i + 1} 个很长的中文接入点名称 · MASQUE');
}
