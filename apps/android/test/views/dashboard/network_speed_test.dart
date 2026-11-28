import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/widgets/traffic.dart';
import 'package:fl_clash/views/dashboard/widgets/warp_usage.dart';
import 'package:fl_clash/views/dashboard/widgets/warp_usage_chart.dart';
import 'package:fl_clash/views/dashboard/widgets/warp_usage_details.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/host_scaffold.dart';
import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

const _size = Size(400, 800);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockCore core;
  late ProviderContainer container;

  setUp(() {
    core = _MockCore();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
      ],
    );
    globalState.container = container;
  });

  tearDown(() => container.dispose());

  Future<void> pumpCard(
    WidgetTester tester,
    Widget card, {
    Size size = _size,
  }) async {
    container.read(viewSizeProvider.notifier).value = size;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: HostScaffold(body: ListView(children: [card])),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> teardownCard(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  void addTraffic(Traffic traffic) =>
      container.read(trafficsProvider.notifier).addTraffic(traffic);

  Finder tileOf(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_SpeedTile',
    ),
  );

  testWidgets('the usage chart switches periods and keeps the active period '
      'when counters update', (tester) async {
    const month = Traffic(up: 1024, down: 3072);
    const lifetime = Traffic(up: 5120, down: 7168);
    const session = Traffic(up: 128, down: 384);
    when(
      () => core.getTrafficUsage(any()),
    ).thenAnswer((_) async => (month: month, total: lifetime));
    container.read(initProvider.notifier).value = true;
    container.read(totalTrafficProvider.notifier).value = session;

    await pumpCard(tester, const WarpUsageCard());
    expect(find.text(_traffic(month.speed)), findsOneWidget);
    await tester.tap(find.text('Traffic usage'));
    await tester.pumpAndSettle();

    final details = find.byType(WarpUsageDetails);
    final ring = find.descendant(of: details, matching: find.byType(UsageRing));
    final legend = find.descendant(
      of: details,
      matching: find.byType(UsageLegend),
    );
    void expectPeriod(Traffic traffic) {
      expect(
        find.descendant(of: ring, matching: find.text(_traffic(traffic.speed))),
        findsOneWidget,
      );
      for (final bytes in [traffic.up, traffic.down]) {
        expect(
          find.descendant(of: legend, matching: find.text(_traffic(bytes))),
          findsOneWidget,
        );
      }
    }

    Future<void> select(String label) async {
      final choice = find.descendant(
        of: find.byWidgetPredicate((widget) => widget is SegmentedControl),
        matching: find.text(label),
      );
      await tester.tap(choice);
      await tester.pumpAndSettle();
    }

    expectPeriod(month);
    await select('All time');
    expectPeriod(lifetime);
    await select('This session');
    expectPeriod(session);
    const updated = Traffic(up: 896, down: 1536);
    container.read(totalTrafficProvider.notifier).value = updated;
    await tester.pump();
    expectPeriod(updated);
    expect(tester.takeException(), isNull);
    await teardownCard(tester);
  });

  testWidgets('a narrow usage card distinguishes an unread counter from zero '
      'with enlarged text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final response = Completer<({Traffic month, Traffic total})>();
    when(() => core.getTrafficUsage(any())).thenAnswer((_) => response.future);
    container.read(initProvider.notifier).value = true;
    await pumpCard(tester, const WarpUsageCard(), size: const Size(320, 600));
    expect(find.text('—'), findsWidgets);
    expect(find.text(_traffic(0)), findsNothing);
    expect(tester.takeException(), isNull);

    response.complete((month: const Traffic(), total: const Traffic()));
    await tester.pump();
    await tester.pump();
    expect(find.text(_traffic(0)), findsWidgets);
    await tester.tap(find.text('Traffic usage'));
    await tester.pumpAndSettle();
    final ring = find.descendant(
      of: find.byType(WarpUsageDetails),
      matching: find.byType(UsageRing),
    );
    expect(
      find.descendant(of: ring, matching: find.text(_traffic(0))),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await teardownCard(tester);
  });

  testWidgets('reads each direction\'s speed and session total', (
    tester,
  ) async {
    addTraffic(const Traffic(up: 2048, down: 4096));
    addTraffic(const Traffic(up: 1024, down: 3072));
    container.read(totalTrafficProvider.notifier).value = const Traffic(
      up: 5120,
      down: 6144,
    );

    await pumpCard(tester, const NetworkSpeedCard());

    final upload = tileOf('Upload');
    final download = tileOf('Download');
    Finder inTile(Finder tile, String text) =>
        find.descendant(of: tile, matching: find.textContaining(text));
    expect(inTile(upload, '${_traffic(1024)}/s'), findsOneWidget);
    expect(inTile(upload, 'Total ${_traffic(5120)}'), findsOneWidget);
    expect(inTile(download, '${_traffic(3072)}/s'), findsOneWidget);
    expect(inTile(download, 'Total ${_traffic(6144)}'), findsOneWidget);
    expect(find.textContaining(_traffic(4096)), findsNothing);

    await teardownCard(tester);
  });

  testWidgets('a phone tile keeps its ratio and charts under its title', (
    tester,
  ) async {
    await pumpCard(tester, const NetworkSpeedCard());

    for (final label in ['Upload', 'Download']) {
      final tile = tileOf(label);
      final rect = tester.getRect(tile);
      expect(rect.height, closeTo(rect.width / 1.45, 0.5));

      final chart = tester.getRect(
        find.descendant(of: tile, matching: find.byType(LineChart)),
      );
      final title = tester.getRect(
        find.descendant(of: tile, matching: find.text(label)),
      );
      expect(chart.top, greaterThanOrEqualTo(title.bottom));
      expect(chart.bottom, greaterThanOrEqualTo(rect.bottom));
    }

    await teardownCard(tester);
  });

  testWidgets('a phone tile grows rather than clip a scaled up total', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpCard(tester, const NetworkSpeedCard());

    final rect = tester.getRect(tileOf('Upload'));
    expect(rect.height, greaterThan(rect.width / 1.45 + 1));
    final total = tester.getRect(find.textContaining('Total').first);
    expect(total.bottom, lessThanOrEqualTo(rect.bottom));
    expect(tester.takeException(), isNull);

    await teardownCard(tester);
  });

  testWidgets('a desktop card keeps its peak to the window it charts', (
    tester,
  ) async {
    addTraffic(const Traffic(up: 1 << 20));
    for (var i = 0; i < trafficSampleLength; i++) {
      addTraffic(const Traffic(up: 2048));
    }

    await pumpCard(tester, const SpeedCard(direction: TrafficDirection.upload));

    expect(find.textContaining(_traffic(1 << 20)), findsNothing);
    expect(find.textContaining('${_traffic(2048)}/s'), findsWidgets);

    await teardownCard(tester);
  });
}

String _traffic(num bytes) {
  final show = bytes.traffic;
  return '${show.value} ${show.unit}';
}
