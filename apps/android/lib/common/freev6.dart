import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FreeV6Storage {
  const FreeV6Storage();

  static const _channel = MethodChannel('dev.freev6.mobile/storage');

  Future<String?> read() async {
    if (!Platform.isWindows) return _channel.invokeMethod<String>('read');
    final prefs = await SharedPreferences.getInstance();
    final encrypted = prefs.getString('flux6.warp.dpapi');
    if (encrypted == null) return null;
    final clear = await _channel.invokeMethod<Uint8List>(
      'unprotect',
      base64Decode(encrypted),
    );
    if (clear == null) throw StateError('Credential store unavailable');
    return utf8.decode(clear);
  }

  Future<void> write(String credentials) async {
    if (!Platform.isWindows) {
      return _channel.invokeMethod<void>('write', credentials);
    }
    final encrypted = await _channel.invokeMethod<Uint8List>(
      'protect',
      Uint8List.fromList(utf8.encode(credentials)),
    );
    final prefs = await SharedPreferences.getInstance();
    if (encrypted == null ||
        !await prefs.setString('flux6.warp.dpapi', base64Encode(encrypted))) {
      throw StateError('Credential store unavailable');
    }
  }
}

enum WarpPreparationStep { storage, registration, profile }

class FreeV6Preparation {
  FreeV6Preparation(this.core, this.storage);

  final CoreHandlerInterface core;
  final FreeV6Storage storage;
  String? _pendingCredentials;
  bool _preparing = false;

  Future<String> prepare(
    List<String> campusTargets, {
    void Function(WarpPreparationStep)? onStep,
  }) async {
    if (_preparing) throw StateError('Flux6 preparation is already running');
    _preparing = true;
    try {
      onStep?.call(WarpPreparationStep.storage);
      var credentials = _pendingCredentials ?? await storage.read();
      if (credentials == null) {
        onStep?.call(WarpPreparationStep.registration);
        credentials =
            await core.invokeMethod(
                  method: CoreMethod.freeV6Register,
                  timeout: const Duration(seconds: 55),
                )
                as String;
        _pendingCredentials = credentials;
      }
      if (_pendingCredentials != null) {
        onStep?.call(WarpPreparationStep.storage);
        await storage.write(credentials);
        _pendingCredentials = null;
      }
      onStep?.call(WarpPreparationStep.profile);
      final profile =
          await core.invokeMethod(
                method: CoreMethod.freeV6Profile,
                arguments: {
                  'credentials': credentials,
                  'campus-targets': campusTargets,
                },
              )
              as String;
      final data = jsonDecode(profile);
      if (data is! Map || data['proxies'] is! List) {
        throw const FormatException('Invalid Flux6 profile');
      }
      return profile;
    } finally {
      _preparing = false;
    }
  }
}
