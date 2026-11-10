// Runs in a uniquely identified QA app; the shipped app uses live_main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';
import 'package:freev6_flutter_preview/live/nodes_page.dart';
import 'package:freev6_flutter_preview/components/flclash.dart';
import 'package:prism_ui/sidebar.dart' show NavigationSidebar;
import 'package:freev6_flutter_preview/live_main.dart' show HostApplication;

const channel = MethodChannel('dev.freev6.host/v1');
final surface = GlobalKey();
late Directory output;
late LiveModel model;
final evidence = <String, dynamic>{};

Future<void> settle([int ms = 360]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

List<SemanticsNode> nodes() {
  final found = <SemanticsNode>[];
  void visit(SemanticsNode n) {
    found.add(n);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  final owner =
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!;
  visit(owner.rootSemanticsNode!);
  return found;
}

void tap(String label) {
  final node = nodes().firstWhere(
    (n) =>
        n.label.split('\n').contains(label) &&
        n.getSemanticsData().hasAction(ui.SemanticsAction.tap),
    orElse: () => throw StateError(
      'Missing action $label: ${nodes().map((n) => n.label).join("|")}',
    ),
  );
  node.owner!.performAction(node.id, ui.SemanticsAction.tap);
}

Future<void> key(String name) async {
  await channel.invokeMethod('visualKey', {'key': name});
  await settle(450);
}

Map<String, List<double>> geometry() {
  final rects = <String, List<double>>{};
  void visit(Element element) {
    final w = element.widget;
    final name = switch (w) {
      CurrentOutboundCard _ => 'connection',
      SpeedCard c => c.upload ? 'upload' : 'download',
      OutboundModeBar _ => 'mode',
      NavigationSidebar _ => 'sidebar',
      _ => null,
    };
    if (name != null) {
      final r = element.renderObject;
      if (r is RenderBox && r.hasSize) {
        final p = r.localToGlobal(Offset.zero);
        rects[name] = [p.dx, p.dy, r.size.width, r.size.height];
      }
    }
    element.visitChildElements(visit);
  }

  visit(surface.currentContext! as Element);
  return rects;
}

Future<void> image(String name, {bool tree = true}) async {
  await WidgetsBinding.instance.endOfFrame;
  final box =
      surface.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final frame = await box.toImage(pixelRatio: 1);
  final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
  frame.dispose();
  await File('${output.path}/$name.png').writeAsBytes(
    bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
  );
  if (tree) {
    evidence[name] = {
      'size': [box.size.width, box.size.height],
      'geometry': geometry(),
      'flutter': nodes()
          .where((n) => n.label.isNotEmpty || n.value.isNotEmpty)
          .map(
            (n) => {
              'label': n.label,
              'value': n.value,
              'tap': n.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            },
          )
          .toList(),
      'appKit': await channel.invokeMethod('visualAX'),
    };
    final nativeRows = (evidence[name]['appKit']['nodes'] as List).cast<Map>();
    final descriptions = nativeRows.map((r) => '${r['label']} ${r['value']}');
    final required = switch (name) {
      'offline-1232' => [
        '上传速度，暂无采样',
        '下载速度，暂无采样',
        '连接',
        '收起',
        '规则，已选中',
        '本月，已选中',
      ],
      'light-1232' => ['上传速度，', '下载速度，', '峰值', '断开'],
      'node-picker' => ['搜索节点', '西区', '使用中'],
      'clear-logs' => ['清空全部本机日志', '所有级别和暂停显示的记录', '清空全部'],
      'settings-640' => ['设置', '通用'],
      _ => <String>[],
    };
    for (final label in required) {
      if (!descriptions.any((s) => s.contains(label))) {
        throw StateError('macOS AX tree for $name is missing $label');
      }
    }
  }
}

Future<void> size(int w, int h) async {
  await model.platform('setSize', {
    'width': w.toDouble(),
    'height': h.toDouble(),
  });
  await settle(450);
}

Future<void> preference(String field, Object value) async {
  await model.command('preferences.set', {
    'window': 'main',
    'field': field,
    'value': value,
  });
  await settle();
}

Future<void> animateButton() async {
  final dir = Directory('${output.path}/motion');
  await dir.create();
  final samples = <int>[];
  final watch = Stopwatch()..start();
  var toggled = false;
  for (var i = 0; i < 22; i++) {
    if (i == 3 && !toggled) {
      tap('断开');
      toggled = true;
    }
    await settle(18);
    samples.add(watch.elapsedMilliseconds);
    await image('motion/${i.toString().padLeft(3, '0')}', tree: false);
  }
  await File('${dir.path}/times.json').writeAsString(jsonEncode(samples));
}

Future<void> audit(String role, bool longNodes) async {
  await model.start();
  await settle(250);
  await settle(650);
  if (Platform.environment['FREEV6_VISUAL_SETUP'] == '1') {
    if (role != 'main') return;
    await preference('appearance', 'light');
    await size(1232, 780);
    await image('setup-light');
    await preference('appearance', 'dark');
    await size(720, 480);
    await image('setup-dark-compact');
    tap('开始配置');
    for (var i = 0; i < 60 && readMap(model.state['setup'])['step'] != 5; i++) {
      await settle(100);
    }
    if (readMap(model.state['setup'])['step'] != 5)
      throw StateError('Setup did not finish');
    await image('setup-complete');
    tap('完成并连接');
    for (var i = 0; i < 60 && !model.connected; i++) {
      await settle(100);
    }
    model.deliverUiAction('goto.nodes');
    await size(1232, 780);
    await model.command('download.start', {'group': 'access', 'node': '西区'});
    await settle(500);
    await image('download-nodes');
    await size(720, 480);
    await image('download-nodes-compact');
    tap('整组测速');
    await settle(700);
    if (readMap(model.state['download'])['completed'] != 3)
      throw StateError('Batch download did not finish all nodes');
    await image('batch-nodes-compact');
    await size(1232, 780);
    await preference('appearance', 'light');
    tap('名称');
    await settle();
    await image('node-sort-menu');
    tap('下载速度（高 → 低）');
    await settle();
    await image('batch-nodes-light');
    await model.command('disconnect');
    model.deliverUiAction('showPreparation');
    await size(720, 480);
    await settle(800);
    await image('maintenance-compact');
    await File('${output.path}/setup-tree.json')
        .writeAsString(jsonEncode(evidence));
    stdout.writeln('VISUAL_ARTIFACTS ${output.path}');
    stdout.writeln('VISUAL PASS');
    await model.platform('quit');
    return;
  }
  if (role == 'settings') {
    await size(640, 440);
    await image('settings-640');
    await File('${output.path}/settings-tree.json')
        .writeAsString(jsonEncode(evidence));
    return;
  }
  if (longNodes) {
    await size(720, 480);
    model.deliverUiAction('goto.nodes');
    await settle();
    await image('long-nodes-720');
    await File('${output.path}/long-tree.json')
        .writeAsString(jsonEncode(evidence));
  } else {
    await preference('appearance', 'light');
    await size(1232, 780);
    await image('offline-1232');
    await key('nodes');
    await key('find');
    if (!nodes().any((n) => n.label.contains('搜索节点')))
      throw StateError('Cmd+2 / Cmd+F failed');
    var searchHasFocus = false;
    void inspect(Element el) {
      final field = el.widget;
      if (field is EditableText &&
          el.findAncestorWidgetOfExactType<LiveNodesPage>() != null &&
          field.focusNode.hasPrimaryFocus) {
        searchHasFocus = true;
      }
      el.visitChildElements(inspect);
    }

    inspect(surface.currentContext! as Element);
    if (!searchHasFocus) throw StateError('Cmd+F failed to focus node search');
    model.deliverUiAction('goto.dashboard');
    await settle();
    await model.chooseNode('access', '西区');
    await model.command('connect');
    // Wait for actual host traffic so the two curves have enough points for comparison.
    final warm = Stopwatch()..start();
    while (model.uploadHistory.length < 18 && warm.elapsed.inSeconds < 40) {
      await settle(350);
    }
    if (model.uploadHistory.length < 12)
      throw StateError('Insufficient service traffic samples');
    await image('light-1232');
    await size(920, 620);
    await image('light-920');
    await size(720, 480);
    await preference('appearance', 'dark');
    await image('dark-720');
    await size(1232, 780);
    await image('dark-1232');
    await preference('appearance', 'light');
    await preference('reduceMotion', true);
    model.deliverUiAction('goto.nodes');
    await settle();
    await image('reduced-nodes');
    model.deliverUiAction('goto.dashboard');
    await settle();
    tap('接入节点，西区');
    await settle();
    await image('node-picker');
    await key('escape');
    if (nodes().any((n) => n.label.contains('选择接入节点')))
      throw StateError('Escape did not close the node chooser');
    model.deliverUiAction('goto.logs');
    await settle();
    tap('清空…');
    await settle();
    await image('clear-logs');
    await key('escape');
    model.deliverUiAction('goto.dashboard');
    await settle();
    await preference('reduceMotion', false);
    await animateButton();
    for (final op in ['begin', 'remove', 'save']) {
      await model.command('layout.edit', {'op': op, 'kind': 'connection'});
    }
    await settle();
    await image('custom-no-connection');
    for (final op in ['begin', 'reset', 'save']) {
      await model.command('layout.edit', {'op': op});
    }
    await model.platform('openSettings');
    for (
      var i = 0;
      i < 80 && !File('${output.path}/settings-tree.json').existsSync();
      i++
    ) {
      await settle(100);
    }
    if (!File('${output.path}/settings-tree.json').existsSync())
      throw StateError('settings capture timed out');
    await File('${output.path}/main-tree.json')
        .writeAsString(jsonEncode(evidence));
  }
  stdout.writeln('VISUAL_ARTIFACTS ${output.path}');
  stdout.writeln('VISUAL PASS');
  await model.platform('quit');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Attach the native AX bridge before Flutter publishes its first full tree.
  if (await channel.invokeMethod<bool>('visualAXEnable') != true) {
    throw StateError('Could not attach the QA window accessibility bridge');
  }
  final role = await channel.invokeMethod<String>('windowRole') ?? 'main';
  output = Directory(
    '${Directory.systemTemp.path}/FreeV6Visual-${Platform.environment["FREEV6_VISUAL_RUN"]!}',
  );
  await output.create(recursive: true);
  model = LiveModel(windowRole: role);
  runApp(
    RepaintBoundary(
      key: surface,
      child: HostApplication(model: model),
    ),
  );
  try {
    await audit(role, Platform.environment['FREEV6_VISUAL_LONG'] == '1');
  } catch (e, st) {
    stderr.writeln('VISUAL FAIL $e\n$st');
    exitCode = 1;
    await model.platform('quit');
  }
}
