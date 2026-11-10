import 'dart:convert';
import 'dart:io';

abstract class PreferencesStore {
  Future<Map<String, String>> load();
  Future<void> save(Map<String, String> values);
}

class MemoryPreferences extends PreferencesStore {
  Map<String, String> values = {};
  @override
  Future<Map<String, String>> load() async => Map.of(values);
  @override
  Future<void> save(Map<String, String> values) async {
    this.values = Map.of(values);
  }
}

class FilePreferences extends PreferencesStore {
  FilePreferences(this.file);
  final File file;
  Future<void> _writing = Future.value();
  Map<String, String> _decode(String data) {
    if (data.length > 8 * 1024 * 1024) throw const FormatException('界面偏好文件过大');
    final raw = jsonDecode(data);
    if (raw is! Map || raw['version'] != 1 || raw['values'] is! Map)
      throw const FormatException('界面偏好格式无效');
    return (raw['values'] as Map).map((k, v) {
      if (k is! String || v is! String) throw const FormatException('界面偏好字段无效');
      return MapEntry(k, v);
    });
  }

  @override
  Future<Map<String, String>> load() async {
    final backup = File('${file.path}.bak');
    if (!await file.exists()) return await backup.exists() ? _read(backup) : {};
    try {
      return await _read(file);
    } on Object {
      if (await backup.exists()) return _read(backup);
      rethrow;
    }
  }

  Future<Map<String, String>> _read(File source) async {
    if (await source.length() > 8 * 1024 * 1024)
      throw const FormatException('界面偏好文件过大');
    return _decode(await source.readAsString());
  }

  @override
  Future<void> save(Map<String, String> values) {
    final payload = jsonEncode({'version': 1, 'values': Map.of(values)});
    final operation = _writing.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(payload, flush: true);
      if (await file.exists()) {
        // Only preserve a parseable previous generation as recovery data.
        try {
          await _read(file);
          await file.copy('${file.path}.bak');
        } on FormatException {
          /* keep the last valid backup */
        }
      }
      await temporary.rename(file.path);
    });
    _writing = operation;
    return operation;
  }
}
