import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/app_theme.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';
import 'package:freev6_flutter_preview/live/pages.dart';

class _PageHost extends LiveModel {
  final calls = <String>[];
  final imports = <String>[];
  final platformCalls = <String>[];
  @override
  Future<dynamic> platform(String method, [StateMap args = const {}]) async {
    platformCalls.add(method);
    return null;
  }

  _PageHost({super.windowRole}) {
    state = {
      'settings': {
        'accepted': true,
        'rules': <String, dynamic>{
          'main': {
            'mode': 'rule',
            'devMode': false,
            'campus': '',
            'blacklist': '',
            'dirty': false,
          },
        },
        'preferences': {'appearance': 'system'},
        'profiles': {
          'chainEnabled': false,
          'cloudEnabled': false,
          'cloudAllowed': true,
          'chainNames': [],
          'cloudNames': [],
        },
        'logs': {'rows': [], 'level': '全部', 'paused': false, 'canClear': true},
      },
    };
  }
  Map get data => state['settings'] as Map;
  Map get rule => (data['rules'] as Map)['main'] as Map;
  @override
  Future<StateMap> command(String action, [StateMap args = const {}]) async {
    calls.add(action);
    if (action == 'rules.edit') {
      rule[args['field']] = args['value'];
      rule['dirty'] = true;
      rule.remove('issue');
    } else if (action == 'rules.save' &&
        (rule['blacklist'] as String).contains('https://')) {
      rule['issue'] = {
        'field': 'blacklist',
        'line': 3,
        'start': 12,
        'length': 16,
        'message': '黑名单第 3 行：请移除协议。',
      };
      notifyListeners();
      throw const LiveCommandError('黑名单第 3 行：请移除协议。');
    } else if (action == 'profile.import') {
      imports.add(args['value'] as String);
      if (imports.length == 1) throw const LiveCommandError('来源连接失败，可以修改后重试。');
    }
    notifyListeners();
    return {'ok': true};
  }
}

void main() {
  testWidgets(
    'failed rule save focuses and selects the original physical line',
    (tester) async {
      final model = _PageHost();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LiveConfigurationPage(model: model)),
        ),
      );
      final blacklist = find.widgetWithText(TextField, '黑名单');
      await tester.ensureVisible(blacklist);
      await tester.enterText(blacklist, 'first.test\n\nhttps://bad.test');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存代理规则'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TextField>(blacklist);
      expect(editor.focusNode!.hasFocus, isTrue);
      expect(
        editor.controller!.selection.textInside(editor.controller!.text),
        'https://bad.test',
      );
      expect(editor.decoration!.errorText, contains('第 3 行'));
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );

  testWidgets(
    'subscription failure keeps the masked input and retry uses edited address',
    (tester) async {
      final model = _PageHost();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LiveConfigurationPage(model: model)),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -470));
      await tester.pumpAndSettle();
      final trigger = find.text('订阅地址').first;
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        field,
        'https://example.invalid/first?token=synthetic',
      );
      await tester.pump();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      expect(
        tester.widget<TextField>(field).controller!.text,
        endsWith('token=synthetic'),
      );
      expect(find.textContaining('来源连接失败'), findsOneWidget);
      await tester.enterText(field, 'https://example.invalid/fixed');
      await tester.pump();
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(model.imports.last, 'https://example.invalid/fixed');
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
  testWidgets(
    'compact settings opens file chooser in this window and cancellation preserves selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 440));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final model = _PageHost(windowRole: 'settings');
      model.data['rules']['settings'] = Map.of(model.rule);
      await tester.pumpWidget(
        FreeV6Theme(
          title: '设置',
          reduceMotion: true,
          home: Scaffold(body: LiveSettingsPage(model: model)),
        ),
      );
      model.deliverUiAction('import');
      await tester.pumpAndSettle();
      expect(model.platformCalls.where((v) => v == 'pickFile'), hasLength(1));
      expect(model.imports, isEmpty);
      expect(find.text('保存代理规则'), findsOneWidget);
      model.deliverUiAction('save');
      await tester.pumpAndSettle();
      expect(model.calls, contains('draft.saveAll'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
}
