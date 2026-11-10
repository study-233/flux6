import 'package:flutter/services.dart';

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

class WindowsHost {
  const WindowsHost({
    this.channel = const MethodChannel('dev.freev6.windows/v1'),
  });
  final MethodChannel channel;
  Future<HostInfo> describe() async =>
      HostInfo.decode(await channel.invokeMethod<Object?>('describe'));
  Future<void> finishProbe(bool ok) =>
      channel.invokeMethod('finishProbe', {'ok': ok});
}
