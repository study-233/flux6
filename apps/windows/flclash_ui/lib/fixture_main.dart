import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/platform/windows_host.dart';
import 'package:window/window.dart';

import 'freev6/application.dart';
import 'freev6/navigation.dart';
import 'freev6/offline_fixture.dart';
import 'freev6/offline_main.dart' show OfflineHttpGuard;
import 'freev6/session.dart';

Future<void> main(List<String> arguments) async {
  if (!const bool.fromEnvironment('FREEV6_OFFLINE') || !safeModeBuild) {
    throw StateError('The fixture target requires both offline guards');
  }
  HttpOverrides.global = OfflineHttpGuard();
  WidgetsFlutterBinding.ensureInitialized();
  final nativeHost = WindowsHost();
  final nativeInfo = await nativeHost.describe();
  if (!nativeInfo.preview) {
    throw StateError('Offline fixtures require a preview native host');
  }
  if (arguments.contains('--host-probe')) {
    final host = nativeHost;
    try {
      await host.finishProbe((await host.describe()).preview);
    } catch (_) {
      await host.finishProbe(false);
    }
    return;
  }
  nativeHost.dispose();
  final fixture = FreeV6OfflineFixture();
  await fixture.model.initialize();
  final session = FreeV6Session(fixture.model, backend: true);
  navigationPort = FreeV6Navigation();
  windowPort = window;
  await desktopWindow.ensureInitialized();
  await desktopWindow.setTitleBarStyle(TitleBarStyle.hidden);
  await desktopWindow.setMinimumSize(const Size(720, 480));
  await desktopWindow.setSize(const Size(1280, 800));
  runApp(
    UncontrolledProviderScope(
      container: session.container,
      child: const FreeV6Prototype(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(desktopWindow.show()),
  );
}
