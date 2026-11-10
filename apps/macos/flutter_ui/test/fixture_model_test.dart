import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/fixture_model.dart';

void main() {
  test(
    'offline preferences survive quitting and apply on the next connection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'freev6-fixture-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = await FixtureModel.load(
        directory: directory,
        periodicSampling: false,
      );
      first.setOnline(false);
      first.selectMode('全局');
      first.selectNode('西区');
      expect(first.connected, isFalse);
      expect(first.currentNode, isNull);
      expect(first.uploadRate, isNull);
      first.dispose();

      final next = await FixtureModel.load(
        directory: directory,
        periodicSampling: false,
      );
      addTearDown(next.dispose);
      expect(next.connected, isFalse);
      expect(next.mode, '全局');
      expect(next.preferredNode, '西区');
      await next.toggleConnection();
      expect(next.currentNode, '西区');
      next.setZeroRate(true);
      expect(next.uploadRate, 0);
      expect(next.downloadRate, 0);
      next.clearLogs();
      expect(next.logs, isEmpty);
      next.setOnline(false);
      expect(next.logs, hasLength(1));
      expect(next.logs.single.message, '已断开连接');
      expect(next.uploadRate, isNull);
    },
  );

  test('late simulated speed checks and connects cannot restore a previous session', () async {
    final model = FixtureModel.memory();
    addTearDown(model.dispose);
    final measuring = model.measure('东区');
    model.setOnline(false);
    final connect = model.toggleConnection();
    model.setOnline(false);
    await Future.wait([measuring, connect]);
    expect(model.connected, isFalse);
    expect(model.currentNode, isNull);
    expect(model.latency('东区'), isNull);
    expect(model.uploadHistory, isEmpty);
  });
}
