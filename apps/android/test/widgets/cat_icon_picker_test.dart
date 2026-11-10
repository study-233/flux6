import 'package:fl_clash/common/cat_icon.dart';
import 'package:fl_clash/widgets/cat_icon_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.cat-icons');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var selected = 'cow';
  var fail = false;
  setUp(() {
    selected = 'cow';
    fail = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getLauncherIcon') return selected;
      if (fail) throw PlatformException(code: 'APP_ICON');
      selected = call.arguments['id'] as String;
      return selected;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('default, restored choice, failed change and retry', () async {
    final icons = CatIconController(channel: channel, isAndroid: true);
    addTearDown(icons.dispose);
    expect(icons.value, CatIcon.cow);
    await icons.select(CatIcon.earth);
    final reopened = CatIconController(channel: channel, isAndroid: true);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.value, CatIcon.earth);
    fail = true;
    await expectLater(
      reopened.select(CatIcon.orange),
      throwsA(isA<PlatformException>()),
    );
    expect(reopened.value, CatIcon.earth);
    fail = false;
    await reopened.select(CatIcon.orange);
    expect(reopened.value, CatIcon.orange);
  });
  testWidgets(
    'all choices render, selection changes and errors keep last choice',
    (tester) async {
      final icons = CatIconController(channel: channel, isAndroid: true);
      await tester.pumpWidget(
        TestApp(
          locale: const Locale('en'),
          child: SingleChildScrollView(child: CatIconPicker(controller: icons)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cow cat (default)'), findsOneWidget);
      await tester.ensureVisible(find.text('Earth cat'));
      await tester.tap(find.text('Earth cat'));
      await tester.pumpAndSettle();
      expect(icons.value, CatIcon.earth);
      fail = true;
      await tester.ensureVisible(find.text('Orange cat'));
      await tester.tap(find.text('Orange cat'));
      await tester.pumpAndSettle();
      expect(icons.value, CatIcon.earth);
      expect(
        find.text('Could not change the icon. Please try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      icons.dispose();
    },
  );
}
