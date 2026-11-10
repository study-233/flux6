import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart'
    show IndexedStack, Scaffold, SizedBox, TextField;
import 'package:freev6_flutter_preview/app_theme.dart';
import 'package:freev6_flutter_preview/live/nodes_page.dart';
import 'package:freev6_flutter_preview/components/proxy_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';

class _NativeEvents extends EventChannel {
  _NativeEvents() : super('tests/freev6/events');
  final controller = StreamController<dynamic>.broadcast(sync: true);
  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) =>
      controller.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tests/freev6/host');
  late _NativeEvents events;
  late LiveModel model;
  late StateMap latest;
  late List<MethodCall> calls;
  StateMap snapshot(int cursor, String phase, {String? session}) => {
    'version': 1,
    'cursor': cursor,
    'phase': phase,
    'sessionId': session,
    'revision': 5,
    'controlToken': 'target',
    'mode': 'global',
    'preferredNode': '西区',
    'currentNode': phase == 'running' ? '西区' : null,
    'groups': [],
    'capabilities': {
      'node': true,
      'mode': true,
      'connect': phase == 'idle',
      'disconnect': phase == 'running',
    },
    'settings': {'accepted': true, 'drafts': {}},
    'sampleSeq': 0,
    'uploadHistory': [],
    'downloadHistory': [],
  };
  void bind(Future<dynamic> Function(MethodCall call) handle) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return handle(call);
        });
  }

  setUp(() {
    events = _NativeEvents();
    model = LiveModel(events: events, channel: channel);
    calls = [];
    latest = snapshot(0, 'idle');
    bind(
      (call) async =>
          call.method == 'snapshot' ? latest : {'ok': true, 'snapshot': latest},
    );
  });
  tearDown(() async {
    model.dispose();
    await events.controller.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'event received during handshake beats older snapshot and stale command reply',
    () async {
      final handshake = Completer<StateMap>(), reply = Completer<StateMap>();
      bind(
        (call) async =>
            call.method == 'snapshot' ? handshake.future : reply.future,
      );
      final starting = model.start();
      latest = snapshot(3, 'running', session: 'new');
      events.controller.add({
        'version': 1,
        'cursor': 3,
        'kind': 'state',
        'snapshot': latest,
      });
      handshake.complete(snapshot(2, 'idle'));
      await starting;
      expect(model.connected, true);
      final saving = model.command('setNode', {
        'group': 'access',
        'node': '西区',
      });
      final envelope = readMap(calls.last.arguments);
      expect(envelope['sessionId'], 'new');
      expect(envelope['controlToken'], 'target');
      final newer = snapshot(4, 'idle');
      events.controller.add({
        'version': 1,
        'cursor': 4,
        'kind': 'state',
        'snapshot': newer,
      });
      reply.complete({'ok': true, 'snapshot': latest});
      await saving;
      expect(model.connected, false);
      expect(model.currentNode, isNull);
      expect(model.preferredNode, '西区');
    },
  );
  test(
    'partial traffic is scoped to one session; missing cursors reload the full view',
    () async {
      latest = snapshot(7, 'running', session: 'A');
      await model.start();
      var redraws = 0;
      model.addListener(() => redraws++);
      events.controller.add({
        'version': 1,
        'cursor': 8,
        'kind': 'traffic',
        'snapshot': {
          'sessionId': 'A',
          'sampleSeq': 1,
          'uploadHistory': [0.0],
          'downloadHistory': [5.0],
        },
      });
      expect(model.uploadHistory, [0.0]);
      expect(model.mode, '全局');
      expect(redraws, 0);
      latest = snapshot(11, 'idle');
      events.controller.add({
        'version': 1,
        'cursor': 11,
        'kind': 'traffic',
        'snapshot': {
          'sessionId': 'discarded',
          'uploadHistory': [45.0],
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(model.phase, 'idle');
      expect(model.uploadHistory, isEmpty);
      expect(calls.where((c) => c.method == 'snapshot'), hasLength(2));
    },
  );
  test(
    'a rejected command preserves the last confirmed node and exposes the native message',
    () async {
      await model.start();
      bind(
        (call) async => {
          'ok': false,
          'snapshot': latest,
          'error': '节点目录已更新',
          'code': 'conflict',
        },
      );
      expect(await model.chooseNode('access', '东区'), false);
      expect(model.message, '节点目录已更新');
      expect(model.preferredNode, '西区');
    },
  );
  test(
    'rapid node choices serialize using the confirmed token and keep the last choice',
    () async {
      latest = snapshot(0, 'running', session: 'A');
      await model.start();
      final first = Completer<StateMap>();
      final writes = <StateMap>[];
      bind((call) async {
        final args = readMap(call.arguments);
        writes.add(args);
        if (writes.length == 1) return first.future;
        latest = {
          ...latest,
          'cursor': 2,
          'preferredNode': readMap(args['arguments'])['node'],
        };
        return {'ok': true, 'snapshot': latest};
      });
      final choosingA = model.chooseNode('access', '西区');
      final superseded = model.chooseNode('access', '北区');
      final choosingB = model.chooseNode('access', '东区');
      expect(await superseded, false);
      latest = {...latest, 'cursor': 1, 'controlToken': 'confirmed-A'};
      first.complete({'ok': true, 'snapshot': latest});
      expect(await choosingA, true);
      expect(await choosingB, true);
      expect(writes.map((v) => readMap(v['arguments'])['node']), ['西区', '东区']);
      expect(writes.last['controlToken'], 'confirmed-A');
      expect(model.preferredNode, '东区');
    },
  );
  testWidgets(
    'a retained hidden node page keeps its query and only accepts find when visible',
    (tester) async {
      await tester.runAsync(() => model.start());
      final nodes = LiveNodesPage(model: model);
      FreeV6Theme window(int page) => FreeV6Theme(
        title: '节点',
        home: Scaffold(
          body: IndexedStack(index: page, children: [const SizedBox(), nodes]),
        ),
      );
      await tester.pumpWidget(window(1));
      await tester.enterText(find.byType(TextField), '东');
      await tester.pumpWidget(window(0));
      model.deliverUiAction('find');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byType(TextField, skipOffstage: false),
      );
      expect(field.focusNode!.hasFocus, false);
      await tester.pumpWidget(window(1));
      model.deliverUiAction('find');
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, true);
      expect(field.controller!.text, '东');
    },
  );
  testWidgets(
    'tapping the delay action in a proxy card does not select that node',
    (tester) async {
      latest = {
        ...snapshot(1, 'running', session: 'A'),
        'group': 'access',
        'groups': [
          {
            'id': 'access',
            'source': 'session',
            'members': ['东区', '西区'],
            'current': '西区',
            'preferred': '西区',
            'latencies': {'东区': 'timeout', '西区': 19},
          },
        ],
        'capabilities': {'node': true, 'measure': true},
      };
      await tester.runAsync(() => model.start());
      await tester.pumpWidget(
        FreeV6Theme(
          title: '节点',
          home: Scaffold(body: LiveNodesPage(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HostProxyCard), findsNWidgets(3));
      expect(find.text('超时'), findsOneWidget);
      await tester.tap(find.byTooltip('测量东区延迟'));
      await tester.pumpAndSettle();
      var commands = calls
          .where((c) => c.method == 'command')
          .map((c) => readMap(c.arguments)['name'])
          .toList();
      expect(commands, ['measure']);
      expect(model.currentNode, '西区');
      await tester.tap(find.text('东区'));
      await tester.pumpAndSettle();
      commands = calls
          .where((c) => c.method == 'command')
          .map((c) => readMap(c.arguments)['name'])
          .toList();
      expect(commands, ['measure', 'setNode']);
      expect(tester.takeException(), isNull);
    },
  );
}
