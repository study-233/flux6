import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/dashboard/widgets/network_speed_chart.dart';
import 'package:fl_clash/views/dashboard/widgets/traffic.dart';
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

  Future<void> pumpCard(WidgetTester tester, Widget card) async {
    container.read(viewSizeProvider.notifier).value = _size;
    tester.view.physicalSize = _size;
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

    final upload = find.byKey(const ValueKey(TrafficDirection.upload));
    final download = find.byKey(const ValueKey(TrafficDirection.download));
    Finder inTile(Finder tile, String text) =>
        find.descendant(of: tile, matching: find.textContaining(text));
    expect(inTile(upload, '${_traffic(1024)}/s'), findsOneWidget);
    expect(inTile(upload, 'This session ${_traffic(5120)}'), findsOneWidget);
    expect(inTile(download, '${_traffic(3072)}/s'), findsOneWidget);
    expect(inTile(download, 'This session ${_traffic(6144)}'), findsOneWidget);
    expect(find.textContaining(_traffic(4096)), findsNothing);

    await teardownCard(tester);
  });

  testWidgets('opens monthly and all-time usage from the network speed card', (
    tester,
  ) async {
    when(() => core.getTrafficUsage(false)).thenAnswer(
      (_) async => (
        month: const Traffic(up: 1024, down: 2048),
        total: const Traffic(up: 4096, down: 8192),
      ),
    );
    await pumpCard(tester, const NetworkSpeedCard());
    await tester.tap(find.text('Network speed'));
    await tester.pumpAndSettle();
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('All time'), findsOneWidget);
    expect(find.text(_traffic(3072)), findsOneWidget);
    expect(find.text(_traffic(12288)), findsOneWidget);
    expect(find.text('Upload ${_traffic(1024)}'), findsOneWidget);
    expect(find.text('Download ${_traffic(8192)}'), findsOneWidget);
    await teardownCard(tester);
  });

  testWidgets(
    'the phone chart scales to the higher direction and resets on clear',
    (tester) async {
      addTraffic(const Traffic(up: 12 * 1024, down: 1024));
      await pumpCard(tester, const NetworkSpeedCard());
      final chart = find.byType(NetworkSpeedChart);
      Finder axis(num bytes) => find.descendant(
        of: chart,
        matching: find.text('${_traffic(bytes)}/s'),
      );
      expect(axis(16 * 1024), findsOneWidget);

      addTraffic(const Traffic(up: 1024, down: 24 * 1024));
      await tester.pump();
      expect(axis(32 * 1024), findsOneWidget);

      container.read(trafficsProvider.notifier).clear();
      await tester.pump();
      expect(axis(8 * 1024), findsOneWidget);
      expect(find.textContaining(_traffic(24 * 1024)), findsNothing);
      await teardownCard(tester);
    },
  );

  testWidgets(
    'both readings stay above the trend with large text on a narrow phone',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpCard(tester, const NetworkSpeedCard());
      tester.view.physicalSize = const Size(320, 800);
      await tester.pump();
      final upload = tester.getRect(
        find.byKey(const ValueKey(TrafficDirection.upload)),
      );
      final download = tester.getRect(
        find.byKey(const ValueKey(TrafficDirection.download)),
      );
      expect(download.top, greaterThanOrEqualTo(upload.bottom));
      expect(
        tester.getRect(find.byType(NetworkSpeedChart)).top,
        greaterThanOrEqualTo(download.bottom),
      );
      expect(tester.takeException(), isNull);
      await teardownCard(tester);
    },
  );

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
