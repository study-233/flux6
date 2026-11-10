import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('dev.freev6.host/v1');
const _events = EventChannel('dev.freev6.host/v1/events');
int _sequence = 0;

Future<Map<dynamic, dynamic>> _snapshot() async =>
    (await _channel.invokeMapMethod<dynamic, dynamic>('snapshot'))!;

Future<Map<dynamic, dynamic>> _send(
  String name,
  Map<String, Object?> arguments, {
  Map<String, Object?> overrides = const {},
}) async {
  final state = await _snapshot();
  return (await _channel.invokeMapMethod<dynamic, dynamic>('command', {
    'version': 1,
    'id': 'smoke-$pid-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
    'name': name,
    'arguments': arguments,
    'sessionId': state['sessionId'],
    'sessionRevision': state['sessionRevision'],
    'controlToken': state['controlToken'],
    'revision': state['revision'],
    ...overrides,
  }))!;
}

Future<Map<dynamic, dynamic>> _command(
  String name, [
  Map<String, Object?> arguments = const {},
]) async {
  final reply = await _send(name, arguments);
  if (reply['ok'] != true) {
    throw StateError('$name: ${reply['code']} ${reply['error']}');
  }
  return reply['snapshot'] as Map<dynamic, dynamic>;
}

Future<Map<dynamic, dynamic>> _logPage([
  Map<String, Object?> args = const {},
]) async {
  final reply = await _send('logs.page', args);
  if (reply['ok'] != true)
    throw StateError('failed to read host log page: ${reply['error']}');
  return reply['data'] as Map<dynamic, dynamic>;
}

void _check(bool success, String description) {
  if (!success) throw StateError(description);
  stdout.writeln('HOST-CHECK $description');
}

Future<void> _waitFor(Future<bool> Function() ready, String description) async {
  final timer = Stopwatch()..start();
  while (!await ready()) {
    if (timer.elapsed > const Duration(seconds: 12)) {
      throw TimeoutException(description);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _settings(File ready) async {
  final window = (await _channel.invokeMapMethod<dynamic, dynamic>(
    'qaWindowInfo',
  ))!;
  stdout.writeln('HOST-WINDOW settings: $window');
  _check(
    window['visible'] == true &&
        (window['width'] as num) >= 640 &&
        (window['height'] as num) >= 440,
    'settings window is visible at its usable native size',
  );
  final state = await _snapshot();
  _check(
    state['mode'] == 'global' && state['preferredNode'] == '西区',
    'settings engine reads the choice from the main window',
  );
  await _command('preferences.set', {
    'field': 'appearance',
    'value': 'dark',
    'window': 'settings',
  });
  await ready.writeAsString('ready');
}

Future<void> _mainWindow(File ready) async {
  var eventCount = 0;
  final subscription = _events.receiveBroadcastStream().listen((event) {
    if (event is Map && event['version'] == 1) eventCount++;
  });
  try {
    final window = (await _channel.invokeMapMethod<dynamic, dynamic>(
      'qaWindowInfo',
    ))!;
    final menu = (window['menu'] as List).toList();
    stdout.writeln('HOST-WINDOW main: $window');
    _check(
      window['delegate'].toString().endsWith('.AppDelegate') &&
          ['文件', '导航', '连接'].every(menu.contains),
      'native app delegate installs File, Navigation and Connection menus',
    );
    final first = await _snapshot();
    _check(
      first['environment'] == 'isolated' &&
          first['phase'] == 'idle' &&
          first['settings']['accepted'] == true,
      'isolated host, QA consent and idle worker',
    );
    _check(
      first['settings']['logs']['storageUnavailable'] == false,
      'journal storage is available in the first native snapshot',
    );
    if (Platform.environment['FREEV6_HOST_SMOKE_ROUND'] == 'reopen') {
      _check(
        first['mode'] == 'global' &&
            first['preferredNode'] == '西区' &&
            first['settings']['preferences']['appearance'] == 'dark',
        'mode, node and settings survive a normal quit',
      );
      final saved = jsonDecode(await _logWitness.readAsString()) as Map;
      await _waitFor(() async {
        final rows = (await _logPage())['rows'] as List;
        return rows.any((event) => event['id'] == saved['new']);
      }, 'post-clear event ID persists across the two app launches');
      final rows = (await _logPage())['rows'] as List;
      _check(
        rows.every((row) => !(saved['old'] as List).contains(row['id'])),
        'new event survived reopen and cleared event IDs did not return',
      );
      stdout.writeln('HOST-SMOKE REOPEN PASS');
    } else {
      if (await ready.exists()) await ready.delete();
      await _command('setMode', {'mode': 'global'});
      await _command('setNode', {'group': 'access', 'node': '西区'});
      await _channel.invokeMethod<void>('openSettings');
      await _waitFor(ready.exists, 'independent settings engine');
      _check(
        (await _snapshot())['settings']['preferences']['appearance'] == 'dark',
        'main engine reads the change from the settings window',
      );
      final connected = await _command('connect');
      _check(
        connected['phase'] == 'running' &&
            connected['currentNode'] == '西区' &&
            connected['liveMode'] == 'global',
        'child reports the preselected mode and node',
      );
      final obsolete = await _send(
        'setMode',
        {'mode': 'direct'},
        overrides: {
          'sessionRevision': (connected['sessionRevision'] as num).toInt() + 1,
        },
      );
      _check(
        obsolete['ok'] == false &&
            obsolete['code'] == 'staleSession' &&
            (await _snapshot())['liveMode'] == 'global',
        'obsolete session revision cannot change the running mode',
      );
      final measured = await _command('measure', {
        'group': 'access',
        'nodes': ['西区'],
      });
      _check(
        measured['latencies']['西区'] is int,
        'latency read back from child',
      );
      await _command('scenario', {'name': 'zeroRate'});
      await _waitFor(() async {
        final sample = await _snapshot();
        return sample['downloadRate'] == 0 && sample['uploadRate'] == 0;
      }, 'zero sample');
      _check((await _command('disconnect'))['phase'] == 'idle', 'disconnect');
      _check(eventCount > 2, 'event subscription received changes');
      final logs = (await _snapshot())['settings']['logs'];
      _check(
        logs['storageUnavailable'] == false,
        'host event journal is writable',
      );
      final oldPage = await _logPage();
      final oldIDs = (oldPage['rows'] as List).map((row) => row['id']).toList();
      _check(oldIDs.isNotEmpty, 'journal contains events from this session');
      final cleared = (await _command('clearLogs'))['settings']['logs'];
      _check(
        cleared['storageUnavailable'] == false &&
            cleared['clearError'] == '' &&
            cleared['count'] == 0 &&
            cleared['epoch'] != logs['epoch'],
        'clearing the real host journal succeeds',
      );
      final stalePage = await _logPage({
        'epoch': logs['epoch'],
        'after': logs['newest'],
      });
      _check(
        stalePage['reset'] == true && (stalePage['rows'] as List).isEmpty,
        'pre-clear cursor cannot resurrect cleared events',
      );
      _check(
        (await _command('connect'))['phase'] == 'running',
        'quit with an owned session',
      );
      await _waitFor(() async {
        final logs = (await _snapshot())['settings']['logs'];
        return logs['storageUnavailable'] == false &&
            (logs['count'] as int) > 0;
      }, 'a new event is recorded after clear');
      final rows = (await _logPage())['rows'] as List;
      await _logWitness.writeAsString(
        jsonEncode({'new': rows.first['id'], 'old': oldIDs}),
      );
      stdout.writeln('HOST-SMOKE PASS');
    }
  } finally {
    await subscription.cancel();
  }
  await stdout.flush();
  // A PASS marker alone cannot catch AppKit hanging during asynchronous termination.
  await _channel.invokeMethod<void>('quit');
}

File get _logWitness =>
    File('${Directory.systemTemp.path}/freev6-smoke-journal-witness.json');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('FreeV6 isolated host test'),
    ),
  );
  try {
    await WidgetsBinding.instance.endOfFrame;
    final role = await _channel.invokeMethod<String>('windowRole');
    final ready = File(
      '${Directory.systemTemp.path}/freev6-host-smoke-settings',
    );
    if (role == 'settings') {
      await _settings(ready);
    } else {
      _check(role == 'main', 'main engine role');
      await _mainWindow(ready);
    }
  } catch (error, trace) {
    stderr.writeln('HOST-SMOKE FAIL $error\n$trace');
    await stderr.flush();
    exit(71);
  }
}
