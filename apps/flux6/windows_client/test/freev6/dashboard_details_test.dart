import 'dart:async';

import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/freev6/application.dart';
import 'package:fl_clash/freev6/navigation.dart';
import 'package:fl_clash/freev6/offline_fixture.dart';
import 'package:fl_clash/freev6/port_settings.dart';
import 'package:fl_clash/freev6/session.dart';
import 'package:fl_clash/freev6/automatic_card.dart';
import 'package:fl_clash/freev6/node_tools_view.dart';
import 'package:fl_clash/live_main.dart' show FreeV6StartupView;
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/dashboard/widgets/service_status.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/tooltip.dart' as prism;
import 'package:prism_ui/inherited.dart' show SheetProvider;
import 'package:prism_ui/prism_ui.dart' as ui;

void main() {
  testWidgets(
    'automatic selection shares the node cards and locks policy edits until confirmed',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window'),
            (call) async => call.method.startsWith('is') ? false : null,
          );
      final fixture = FreeV6OfflineFixture(polling: false);
      await fixture.model.initialize();
      await fixture.model.toggleConnection();
      final session = FreeV6Session(fixture.model, backend: true);
      navigationPort = FreeV6Navigation();
      final gate = Completer<void>();
      try {
        session.container
            .read(currentPageLabelProvider.notifier)
            .toPage(PageLabel.proxies);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: session.container,
            child: const FreeV6Prototype(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          session.container.read(selectedProxyNameProvider(accessGroup)),
          automaticProxyName,
        );
        expect(find.byType(FreeV6AutomaticCard), findsOneWidget);
        await tester.tap(find.text('西区 · IPv6').last);
        await tester.pumpAndSettle();
        expect(fixture.model.nodeTools.pinned, '西区 · IPv6');
        expect(
          session.container.read(selectedProxyNameProvider(accessGroup)),
          '西区 · IPv6',
        );
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is prism.Tooltip && w.message == '测速与优选',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('手动固定'), findsOneWidget);
        expect(find.text('并发接入点'), findsNothing);
        fixture.transport.intercept = (r) async {
          if (r.method == 'PUT' && r.uri.path.endsWith('/nodes/quality')) {
            await gate.future;
          }
          return null;
        };
        await tester.tap(find.text('恢复自动'));
        await tester.pump();
        expect(fixture.model.nodeTools.selecting, true);
        expect(find.text('恢复自动'), findsNothing);
        expect(fixture.model.nodeTools.pinned, '西区 · IPv6');
        gate.complete();
        await tester.pumpAndSettle();
        expect(fixture.model.nodeTools.pinned, isEmpty);
        expect(find.text('并发接入点'), findsOneWidget);
        expect(find.text('当前参与优选'), findsOneWidget);
        await tester.tap(find.text('下载测速').first);
        await tester.pumpAndSettle();
        expect(find.text('下载连接数'), findsOneWidget);
        expect(find.text('当前参与优选'), findsNothing);
        await tester.tap(find.text('历史记录'));
        await tester.pumpAndSettle();
        expect(find.text('节点切换记录'), findsOneWidget);
        Navigator.of(tester.element(find.byType(FreeV6NodeToolsView))).pop();
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(720, 480);
        await session.act('preferences.set', {
          'key': 'freev6-theme',
          'value': 'dark',
        });
        await tester.pumpAndSettle();
        await tester.tap(find.text('西区 · IPv6').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FreeV6AutomaticCard));
        await tester.pumpAndSettle();
        expect(fixture.model.nodeTools.pinned, isEmpty);
        expect(
          session.container.read(selectedProxyNameProvider(accessGroup)),
          automaticProxyName,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        fixture.host.dispose();
        tester.view.reset();
        navigationPort = null;
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('startup uses themed text and exposes retry only after failure', (
    tester,
  ) async {
    var retries = 0, exits = 0;
    Widget startup(bool loading) => ui.PrismApp(
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        AppUiLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      home: FreeV6StartupView(
        loading: loading,
        error: loading ? null : 'fixture failure',
        retry: () => retries++,
        quit: () => exits++,
      ),
    );
    await tester.pumpWidget(startup(true));
    await tester.pump(const Duration(milliseconds: 200));
    final loadingText = find.text('正在连接后台服务…');
    expect(loadingText, findsOneWidget);
    final style = DefaultTextStyle.of(tester.element(loadingText)).style;
    expect(style.color, isNot(const Color(0xD0FF0000)));
    expect(style.decoration, isNot(TextDecoration.underline));
    expect(find.text('重试'), findsNothing);
    await tester.pumpWidget(startup(false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.tap(find.text('停止并退出'));
    expect(retries, 1);
    expect(exits, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'exit details, service checks and port edits reach the Windows adapters',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window'),
            (call) async => call.method.startsWith('is') ? false : null,
          );
      final fixture = FreeV6OfflineFixture(polling: false);
      await fixture.model.initialize();
      final session = FreeV6Session(fixture.model, backend: true);
      navigationPort = FreeV6Navigation();
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: session.container,
            child: const FreeV6Prototype(),
          ),
        );
        await tester.runAsync(fixture.model.toggleConnection);
        await tester.pumpAndSettle();
        expect(find.text('203.0.113.42'), findsOneWidget);
        await tester.tap(find.text('203.0.113.42'));
        await tester.pumpAndSettle();
        expect(find.text('Preview Network'), findsWidgets);
        Navigator.of(tester.element(find.text('Preview Network').last)).pop();
        await tester.pumpAndSettle();

        final serviceButton = find.descendant(
          of: find.byType(ServiceStatusCard),
          matching: find.byWidgetPredicate(
            (w) => w is prism.Tooltip && w.message == '服务状态',
          ),
        );
        await tester.tap(serviceButton.first);
        await tester.pumpAndSettle();
        expect(find.byType(ServiceStatusSheet), findsOneWidget);
        final checkAll = find.byWidgetPredicate(
          (w) => w is prism.Tooltip && w.message == '全部检测',
        );
        await tester.tap(checkAll);
        await tester.pumpAndSettle();
        expect(
          fixture.transport.requests.where(
            (r) =>
                r.uri.path.endsWith('/diagnostics/probe') &&
                (r.body['names'] as List? ?? []).contains('netflix'),
          ),
          isNotEmpty,
        );
        SheetProvider.of(tester.element(find.byType(ServiceStatusSheet)))!
            .onClose!();
        await tester.pumpAndSettle();

        session.container
            .read(currentPageLabelProvider.notifier)
            .toPage(PageLabel.tools);
        await tester.pumpAndSettle();
        await tester.tap(find.text('端口设置'));
        await tester.pumpAndSettle();
        final fields = find.byType(EditableText);
        await tester.enterText(fields.at(1), '7890');
        await tester.pumpAndSettle();
        final form = tester.widget<FormPage>(find.byType(FormPage));
        expect(form.error, isNotNull);
        form.onSave();
        await tester.pumpAndSettle();
        expect(find.byType(FreeV6PortForm), findsOneWidget);
        expect(
          fixture.transport.requests.where(
            (r) => r.method == 'PUT' && r.uri.path.endsWith('/network-options'),
          ),
          isEmpty,
        );
        await tester.enterText(fields.at(0), '17890');
        await tester.enterText(fields.at(1), '17891');
        await tester.pumpAndSettle();
        tester.widget<FormPage>(find.byType(FormPage)).onSave();
        await tester.pumpAndSettle();
        expect(fixture.transport.networkOptions['mixedPort'], 17890);
        expect(fixture.transport.networkOptions['httpPort'], 17891);
        expect(find.byType(FreeV6PortForm), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        fixture.host.dispose();
        tester.view.reset();
        navigationPort = null;
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
