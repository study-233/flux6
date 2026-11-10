import 'dart:async';

import 'package:flutter/services.dart';

abstract class DesktopHost {
  Future<Object?> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]);
  Stream<String> get events;
  void dispose() {}
}

class HostInfo {
  const HostInfo({required this.platform, required this.preview});
  final String platform;
  final bool preview;

  factory HostInfo.decode(Object? raw) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['platform'] != 'windows' ||
        raw['preview'] is! bool) {
      throw const FormatException('Windows 宿主协议不兼容');
    }
    return HostInfo(
      platform: raw['platform'] as String,
      preview: raw['preview'] as bool,
    );
  }
}

class WindowsHost extends DesktopHost {
  WindowsHost({this.channel = const MethodChannel('dev.freev6.windows/v1')}) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is String)
        _events.add(call.arguments as String);
    });
  }
  final MethodChannel channel;
  final _events = StreamController<String>.broadcast();
  @override
  Stream<String> get events => _events.stream;
  @override
  Future<Object?> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) => channel.invokeMethod<Object?>(method, arguments);
  Future<HostInfo> describe() async =>
      HostInfo.decode(await channel.invokeMethod<Object?>('describe'));
  Future<void> finishProbe(bool ok) =>
      channel.invokeMethod('finishProbe', {'ok': ok});
  @override
  void dispose() {
    channel.setMethodCallHandler(null);
    _events.close();
  }
}
