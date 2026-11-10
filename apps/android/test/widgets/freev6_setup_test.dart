import 'package:fl_clash/common/freev6.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/freev6/setup.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/freev6_test.dart' show RecordingCore;
import '../helpers/test_app.dart';

void main() {
  const channel = MethodChannel('dev.freev6.mobile/storage');
  const usable = {
    'wifi': true,
    'hasAddress': true,
    'defaultRoute': true,
    'addresses': ['fdd6:82f6:9394::929'],
    'reachable': true,
  };
  late RecordingCore core;
  late ProviderContainer container;
  Map<String, dynamic> network = usable;
  var reads = 0;
  var failProbe = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    core = RecordingCore();
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = container;
    network = usable;
    reads = 0;
    failProbe = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'network') {
            if (failProbe) throw PlatformException(code: 'unavailable');
            return network;
          }
          if (call.method == 'read') {
            reads++;
            throw PlatformException(code: 'stop-before-registration');
          }
          return null;
        });
  });

  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(
    WidgetTester tester, {
    FreeV6ViewMode mode = FreeV6ViewMode.setup,
    Size size = const Size(375, 812),
    double scale = 1,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    container.read(viewSizeProvider.notifier).value = size;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          includeNavigatorKey: false,
          locale: const Locale('en'),
          themeMode: themeMode,
          child: FreeV6View(mode: mode),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'existing profiles migrate past onboarding without account access',
    () async {
      expect(await FreeV6Onboarding().shouldShow(hasProfiles: true), isFalse);
      expect(await FreeV6Onboarding().shouldShow(hasProfiles: false), isFalse);
      expect(reads, 0);
      expect(core.registrations, 0);
    },
  );

  test(
    'a fresh install shows onboarding only until completion or skip',
    () async {
      final onboarding = FreeV6Onboarding();
      expect(await onboarding.shouldShow(hasProfiles: false), isTrue);
      await onboarding.complete();
      expect(await onboarding.shouldShow(hasProfiles: false), isFalse);
    },
  );

  for (final scenario in [
    ({'wifi': false}, 'Connect to Wi-Fi'),
    ({'wifi': true, 'hasAddress': false}, 'no usable IPv6 address'),
    (
      {'wifi': true, 'hasAddress': true, 'defaultRoute': false},
      'no IPv6 default route',
    ),
  ]) {
    testWidgets('setup reports ${scenario.$2} without registering', (
      tester,
    ) async {
      network = scenario.$1;
      await pump(tester);
      await tester.tap(find.text('Check Wi-Fi IPv6'));
      await tester.pumpAndSettle();
      expect(find.textContaining(scenario.$2), findsWidgets);
      expect(find.text('Continue'), findsNothing);
      expect(reads, 0);
      expect(core.registrations, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reachable in [true, false]) {
    testWidgets('private IPv6 continues when TCP probe is $reachable', (
      tester,
    ) async {
      network = {...usable, 'reachable': reachable};
      await pump(tester);
      await tester.tap(find.text('Check Wi-Fi IPv6'));
      await tester.pumpAndSettle();
      expect(find.textContaining('fdd6:'), findsNothing);
      await tester.ensureVisible(find.text('View details'));
      await tester.tap(find.text('View details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('fdd6:'), findsOneWidget);
      expect(
        find.textContaining(reachable ? 'probe succeeded' : 'Neither IPv6'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Campus bypass · optional'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('Prepare FreeV6'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.textContaining('Preparation failed'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('diagnostics stays separate from setup and can retry an error', (
    tester,
  ) async {
    failProbe = true;
    await pump(tester, mode: FreeV6ViewMode.diagnostics);
    await tester.tap(find.text('Check Wi-Fi IPv6'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Network check failed'), findsOneWidget);
    failProbe = false;
    await tester.tap(find.text('Check Wi-Fi IPv6'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi is ready'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(800, 1100),
  ]) {
    testWidgets('welcome fits $size with large type and dark theme', (
      tester,
    ) async {
      await pump(
        tester,
        mode: FreeV6ViewMode.onboarding,
        size: size,
        scale: 2,
        themeMode: ThemeMode.dark,
      );
      expect(find.text('Welcome to FreeV6'), findsOneWidget);
      expect(find.text('Set up later'), findsOneWidget);
      expect(
        tester.getRect(find.text('Get started')).bottom,
        lessThan(size.height),
      );
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(find.text('Check Wi-Fi IPv6'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
