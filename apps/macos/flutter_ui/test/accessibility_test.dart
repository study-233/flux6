import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/components/flclash.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';
import 'package:freev6_flutter_preview/live/nodes_page.dart';
import 'package:freev6_flutter_preview/live/pages.dart';
import 'package:freev6_flutter_preview/live_main.dart';

class _AuditHost extends LiveModel {
  _AuditHost({bool occupied = false, super.windowRole}) {
    state = {
      'phase': occupied ? 'occupied' : 'idle',
      'environment': 'isolated',
      'mode': occupied ? null : 'rule',
      'group': 'access',
      'groups': [
        {
          'id': 'access',
          'members': members,
          'source': 'configuration',
          'preferred': members.first,
        },
      ],
      'profileName': '校园 IPv6',
      'preferredNode': members.first,
      'capabilities': {
        'mode': !occupied,
        'node': !occupied,
        'connect': !occupied,
        'measure': false,
      },
      'settings': {
        'accepted': true,
        'preferences': {'reduceMotion': true},
        'rules': {},
        'drafts': {},
      },
      'logs': [],
      'uploadHistory': [],
      'downloadHistory': [],
    };
  }
  static final members = List.generate(
    28,
    (i) => '校园接入节点 · ${i.toString().padLeft(2, "0")} · 中文名称很长时仍可分辨和选择',
  );
  String? chosen;
  @override
  Future<bool> chooseNode(String id, String? node) async {
    chosen = node;
    return true;
  }

  @override
  Future<dynamic> platform(String method, [StateMap args = const {}]) async =>
      null;
  @override
  Future<StateMap> command(String action, [StateMap args = const {}]) async => {
    'ok': true,
  };
}

void window(WidgetTester t, Size size) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
}

void main() {
  testWidgets(
    'missing samples and measured zero are distinct accessibility values',
    (t) async {
      final model = _AuditHost();
      await t.pumpWidget(HostApplication(model: model));
      await t.pumpAndSettle();
      expect(find.bySemanticsLabel('规则，已选中'), findsOneWidget);
      expect(find.bySemanticsLabel('本月，已选中'), findsOneWidget);
      final up = find.bySemanticsLabel(RegExp('^上传速度'));
      expect(t.getSemantics(up).label, contains('暂无采样'));
      model.state['uploadHistory'] = [0.0];
      model.traffic.value++;
      await t.pumpAndSettle();
      expect(t.getSemantics(up).label, contains('0 B/s'));
      expect(t.getSemantics(up).label, isNot(contains('暂无采样')));
      expect(t.getSemantics(find.bySemanticsLabel('展开')), isNotNull);
    },
  );
  testWidgets('occupied and unknown mode expose no actionable segments', (
    t,
  ) async {
    window(t, const Size(1232, 780));
    await t.pumpWidget(HostApplication(model: _AuditHost(occupied: true)));
    await t.pumpAndSettle();
    for (final mode in ['规则', '全局', '直连']) {
      final node = t.getSemantics(find.bySemanticsLabel(mode));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), false);
    }
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'keyboard picker searches 28 nodes, commits the highlighted row and restores focus on escape',
    (t) async {
      window(t, const Size(720, 480));
      final model = _AuditHost(), trigger = FocusNode();
      addTearDown(trigger.dispose);
      addTearDown(model.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                focusNode: trigger,
                onPressed: () => openLiveNodePicker(context, model),
                child: const Text('接入节点'),
              ),
            ),
          ),
        ),
      );
      trigger.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await t.enterText(find.byType(TextField), '校园接入节点');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(model.chosen, _AuditHost.members[1]);
      expect(trigger.hasFocus, true);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(trigger.hasFocus, true);
    },
  );
  testWidgets(
    'dashboard and independent settings fit compact windows with enlarged Chinese text',
    (t) async {
      t.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      window(t, const Size(720, 480));
      await t.pumpWidget(HostApplication(model: _AuditHost()));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byType(OutboundModeBar));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      t.view.physicalSize = const Size(640, 440);
      await t.pumpWidget(
        HostApplication(model: _AuditHost(windowRole: 'settings')),
      );
      await t.pumpAndSettle();
      expect(find.byType(LiveSettingsPage), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
