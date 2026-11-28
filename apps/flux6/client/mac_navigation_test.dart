import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/mac_host/app_theme.dart';
import 'package:fl_clash/mac_host/live/live_model.dart';
import 'package:fl_clash/mac_host/live_main.dart';
import 'package:fl_clash/mac_navigation.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/views/proxies/group_tabs.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/sidebar.dart';

void main() {
  testWidgets('host toolbar stays available on the shared nodes page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = LiveModel()
      ..state = {
        'phase': 'idle',
        'environment': 'isolated',
        'settings': {'accepted': true, 'setupCompleted': true},
        'capabilities': {'connect': true},
      };
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(model.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(model.channel, null));
    await tester.pumpWidget(
      HostApplication(
        model: model,
        navigation: MacNavigation.new,
        nodeGroups: MacNodeGroups.new,
      ),
    );
    await tester.pumpAndSettle();
    model.deliverUiAction('goto.nodes');
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(
      find
          .text(model.needsPreparation ? '准备服务' : model.connectionAction)
          .hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('设置（⌘,）'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), contains('openSettings'));
  });

  testWidgets('node tabs send a group change and follow a host selection', (
    tester,
  ) async {
    var current = 0;
    late StateSetter update;
    await tester.pumpWidget(
      FreeV6Theme(
        title: 'Flux6',
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            delegates: const [AppLocalizations.delegate],
            child: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return Center(
                  child: SizedBox(
                    height: 56,
                    child: MacNodeGroups(
                      const ['Access', 'Chain'],
                      current,
                      (next) => setState(() => current = next),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chain'));
    await tester.pumpAndSettle();
    expect(current, 1);
    update(() => current = 0);
    await tester.pumpAndSettle();
    expect(
      tester.widget<GroupTabs>(find.byType(GroupTabs)).controller.index,
      0,
    );
  });

  testWidgets(
    'FlClash navigation and Mac menu requests share the active page',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var current = 0;
      late StateSetter update;
      await tester.pumpWidget(
        FreeV6Theme(
          title: 'Flux6',
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MacNavigation(
                [
                  for (var i = 0; i < 4; i++)
                    Center(child: Text('host-page-$i')),
                ],
                current,
                (next) => setState(() => current = next),
                () => fail('Page navigation requested application exit'),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
      final sidebar = tester.widget<NavigationSidebar>(
        find.byType(NavigationSidebar),
      );
      sidebar.onSelected(1);
      await tester.pumpAndSettle();
      expect(current, 1);
      expect(find.text('host-page-1').hitTestable(), findsOneWidget);
      update(() => current = 3);
      await tester.pumpAndSettle();
      expect(find.text('host-page-3').hitTestable(), findsOneWidget);
      expect(MacNavigation.labels[current], PageLabel.logs);
    },
  );
}
