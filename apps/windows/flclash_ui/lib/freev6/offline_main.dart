import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window/window.dart';

import 'application.dart';
export 'application.dart' show FreeV6Prototype;
import 'navigation.dart';
import 'session.dart';

class OfflineHttpGuard extends HttpOverrides {
  static int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('This offline preview cannot create an HTTP client');
  }
}

Future<void> main(List<String> args) async {
  if (!const bool.fromEnvironment('FREEV6_OFFLINE') || !safeModeBuild) {
    throw StateError(
      'Build this preview with FREEV6_OFFLINE=true and SAFE_MODE=true',
    );
  }
  HttpOverrides.global = OfflineHttpGuard();
  WidgetsFlutterBinding.ensureInitialized();
  final session = FreeV6Session(OfflineFreeV6Model());
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
