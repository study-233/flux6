import 'dart:convert';

/// The export contains UI preferences only, never helper credentials.
class LegacyPreferences {
  LegacyPreferences._(this.values);
  final Map<String, String> values;
  static const maxBytes = 6 * 1024 * 1024;
  static const keys = {
    'freev6-theme',
    'freev6-dynamic-color',
    'freev6-pure-black',
    'freev6-bg-mode',
    'freev6-webgl-glass',
    'freev6-wallpaper',
    'freev6-guide-done',
    'freev6-skip-version',
    'freev6-notice-read',
    'freev6-traffic-stats',
    'freev6-halloween-force',
    'freev6-halloween-greeted',
  };

  factory LegacyPreferences.decode(String text) {
    if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
      throw const FormatException('界面备份超过 6 MiB');
    }
    final raw = jsonDecode(text);
    if (raw is! Map ||
        raw['format'] != 'freev6-ui-preferences' ||
        raw['version'] != 1 ||
        raw['values'] is! Map) {
      throw const FormatException('无法识别界面备份格式');
    }
    final values = <String, String>{};
    for (final entry in (raw['values'] as Map).entries) {
      if (!keys.contains(entry.key) || entry.value is! String) {
        throw const FormatException('界面备份包含未知字段');
      }
      values[entry.key as String] = entry.value as String;
    }
    void choice(String key, Set<String> allowed) {
      if (values.containsKey(key) && !allowed.contains(values[key])) {
        throw FormatException('界面备份字段无效：$key');
      }
    }

    choice('freev6-theme', {'system', 'light', 'dark'});
    choice('freev6-bg-mode', {'default', 'wallpaper', 'mica', 'acrylic'});
    for (final key in [
      'freev6-dynamic-color',
      'freev6-pure-black',
      'freev6-webgl-glass',
      'freev6-guide-done',
      'freev6-halloween-force',
    ]) {
      choice(key, {'0', '1'});
    }
    if (values['freev6-wallpaper'] case final String image) {
      if (!image.startsWith('data:image/jpeg;base64,') &&
          !image.startsWith('data:image/png;base64,')) {
        throw const FormatException('壁纸必须是内嵌 JPEG 或 PNG');
      }
      base64Decode(image.substring(image.indexOf(',') + 1));
    }
    if (values['freev6-notice-read'] case final String read) {
      final ids = jsonDecode(read);
      if (ids is! List || ids.length > 50 || ids.any((id) => id is! String)) {
        throw const FormatException('公告已读记录无效');
      }
    }
    if (values['freev6-traffic-stats'] case final String stats) {
      final data = jsonDecode(stats);
      void counters(Object? raw) {
        if (raw is! Map ||
            ['up', 'down'].any((key) {
              final value = raw[key];
              return value is! num || !value.isFinite || value < 0;
            }))
          throw const FormatException('流量历史无效');
      }

      if (data is! Map || data['months'] is! Map)
        throw const FormatException('流量历史无效');
      counters(data['total']);
      for (final month in (data['months'] as Map).entries) {
        if (month.key is! String ||
            !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month.key)) {
          throw const FormatException('流量月份无效');
        }
        counters(month.value);
      }
    }
    return LegacyPreferences._(Map.unmodifiable(values));
  }

  String encode() => jsonEncode({
    'format': 'freev6-ui-preferences',
    'version': 1,
    'values': values,
  });
}
