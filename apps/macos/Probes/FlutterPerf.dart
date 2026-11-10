// Built only inside the isolated benchmark clone. All page rendering and
// commands below go through the shipped HostApplication and LiveModel.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';
import 'package:freev6_flutter_preview/live_main.dart' show HostApplication;

const channel = MethodChannel('dev.freev6.host/v1');
Future<dynamic> native(String method, [Map<String, Object?>? args]) =>
    channel.invokeMethod<dynamic>(method, args);
Future<void> delay(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
void check(bool value, String msg) {
  if (!value) throw StateError(msg);
}

int get frame => PlatformDispatcher.instance.frameData.frameNumber;
const pages = ['nodes', 'config', 'logs', 'dashboard'];

Future<void> main() async {
  try {
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final timings = <FrameTiming>[];
    SchedulerBinding.instance.addTimingsCallback(timings.addAll);
    final width = int.parse(Platform.environment['FREEV6_PERF_WIDTH']!);
    final count = int.parse(Platform.environment['FREEV6_PERF_NODES']!);
    final online = Platform.environment['FREEV6_PERF_ONLINE'] == '1';
    final height = width == 720
        ? 480
        : width == 920
        ? 620
        : 800;
    check(await native('windowRole') == 'main', 'main window required');
    final model = LiveModel(windowRole: 'main');
    runApp(HostApplication(model: model));
    await model.start();
    await native('setSize', {'width': width, 'height': height});
    for (int i = 0; model.nodes.isEmpty && i < 30; ++i) {
      await delay(100);
    }
    check(
      model.nodes.length == count,
      'catalog ${model.nodes.length} != $count (${model.phase} ${model.message})',
    );
    if (online) await model.command('connect');
    check(
      model.connected == online && model.nodes.length == count,
      'wrong session ${model.phase} / ${model.nodes.length}',
    );
    final info = await native('perfInfo');
    check(info['visible'] == true, 'real window required: $info');
    final size = await native('qaWindowInfo');
    check(
      size['width'] == width && size['height'] == height,
      'unexpected window size $size',
    );
    await binding.endOfFrame;
    stdout.writeln(
      'PERFREADY ${jsonEncode({'phase': model.phase, 'count': model.nodes.length, 'window': size, 'display': info})}',
    );
    final steady =
        int.tryParse(Platform.environment['FREEV6_PERF_STEADY'] ?? '') ?? 0;
    if (steady > 0) {
      await native('perfPause');
      stdout.writeln('PERFSTEADY start');
      await delay(steady * 1000);
      stdout.writeln('PERFSTEADY end');
      await native('perfResume');
    }
    await delay(280);
    final stages = <Map<String, dynamic>>[];
    Future<void> stage(String name, Future<void> Function() action) async {
      await native('perfStart');
      final first = frame;
      final watch = Stopwatch()..start();
      await action();
      final last = frame;
      final ticks = await native('perfEnd');
      stages.add({
        'name': name,
        'durationUs': watch.elapsedMicroseconds,
        'first': first,
        'last': last,
        'mainUs': ticks['mainUs'],
        'cvUs': ticks['cvUs'],
        'thermal': ticks['thermal'],
      });
    }

    Future<void> navigate(int steps) async {
      for (int i = 0; i < steps; ++i) {
        model.deliverUiAction('goto.${pages[i % 4]}');
        await delay(105);
      }
    }

    await stage('first4', () => navigate(4));
    await delay(180);
    await stage('nav32', () => navigate(32));
    await delay(180);
    await stage('resize', () async {
      for (int i = 0; i <= 24; ++i) {
        final delta = (80 * sin(pi * i / 24)).round();
        await native('setSize', {
          'width': width + delta,
          'height': height + delta ~/ 2,
        });
        await delay(16);
      }
    });
    await stage('move', () async {
      final positions = <String>{};
      for (int i = 0; i <= 24; ++i) {
        final delta = (48 * sin(pi * 2 * i / 24)).round();
        positions.add((await native('perfMove', {'delta': delta})).toString());
        await delay(16);
      }
      check(positions.length > 8, 'window did not move');
    });
    if (Platform.environment['FREEV6_PERF_MANUAL'] == '1') {
      await stage('manualDrag', () async {
        final window = await native('perfManualStart');
        check(window['active'] == true && window['visible'] == true, 'QA window must be frontmost for manual drag');
        stdout.writeln('PERFDRAGREADY ${jsonEncode(window)}');
        await stdout.flush();
        Map<String, dynamic> result = {};
        for (int i = 0; i < 90; i++) {
          await delay(500);
          result = Map<String, dynamic>.from(await native('perfPointerReport'));
          if (result['nativeDragCalls'] > 0 &&
              (result['deltaX'].abs() > 8 || result['deltaY'].abs() > 8)) break;
        }
        result['pointerRestored'] = await native('perfManualEnd');
        stdout.writeln('PERFMANUAL ${jsonEncode(result)}');
      });
    }
    if (Platform.environment['FREEV6_PERF_POINTER'] == '1') {
      await stage('pointer', () async {
        final attempts = <Map<String, dynamic>>[];
        for (final delivery in ['appKit', 'targetPid']) {
          await native('perfPointerStart', {'delivery': delivery});
          await delay(560);
          final result = Map<String, dynamic>.from(await native('perfPointerReport'));
          attempts.add({'delivery': delivery, ...result});
          if (result['nativeDragCalls'] > 0 && result['deltaX'].abs() > 2) break;
        }
        stdout.writeln('PERFPOINTER ${jsonEncode(attempts)}');
      });
    }
    await stage('actions', () async {
      model.deliverUiAction('goto.nodes');
      final writes = <Future<bool>>[];
      for (int i = 0; i < 12; ++i) {
        writes.add(model.chooseNode(model.group, model.nodes[i % count]));
        await delay(9);
      }
      await Future.wait(writes);
      final expected = model.nodes[11 % count];
      check(
        (online ? model.currentNode : model.preferredNode) == expected,
        'last choice did not reach host',
      );
      await delay(180);
    });
    // Engine timing reports are batched in release. Drain them before matching
    // their real engine frame number to the boundaries of each operation.
    await delay(1300);
    for (final item in stages) {
      final frames = timings.where(
        (t) =>
            t.frameNumber > (item['first'] as int) &&
            t.frameNumber <= (item['last'] as int),
      );
      item['frameUs'] = [
        for (final t in frames)
          [
            t.frameNumber,
            t.buildDuration.inMicroseconds,
            t.rasterDuration.inMicroseconds,
            t.totalSpan.inMicroseconds,
          ],
      ];
      stdout.writeln('PERFSTAGE ${jsonEncode(item)}');
    }
    if (online) await model.command('disconnect');
    check(model.phase == 'idle', 'session left open');
    stdout.writeln('PERFPASS');
    await stdout.flush();
    await native('quit');
  } catch (e, st) {
    stderr.writeln('PERFFAIL $e\n$st');
    exit(2);
  }
}
