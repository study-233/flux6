import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'constant.dart';
import 'system.dart';

enum CatIcon {
  cow('cow'),
  orange('orange'),
  prism('prism'),
  fourColor('four-color'),
  earth('earth');

  const CatIcon(this.id);
  final String id;
  String get asset => 'assets/images/cats/$id.png';
  static CatIcon parse(String? id) =>
      values.firstWhere((icon) => icon.id == id, orElse: () => cow);
}

class CatIconController extends ValueNotifier<CatIcon> {
  CatIconController({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel('$packageName/app'),
      _isAndroid = isAndroid ?? system.isAndroid,
      super(CatIcon.cow);

  final MethodChannel _channel;
  final bool _isAndroid;
  Future<void>? _loading;
  bool _changing = false;

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      if (_isAndroid) {
        value = CatIcon.parse(
          await _channel.invokeMethod<String>('getLauncherIcon'),
        );
      }
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<void> select(CatIcon icon) async {
    if (_changing) return;
    _changing = true;
    try {
      await load();
      if (_isAndroid) {
        final selected = await _channel.invokeMethod<String>(
          'setLauncherIcon',
          {'id': icon.id},
        );
        if (selected != icon.id) throw PlatformException(code: 'APP_ICON');
      }
      value = icon;
    } finally {
      _changing = false;
    }
  }
}

final catIconController = CatIconController();
