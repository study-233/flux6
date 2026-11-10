import 'dart:convert';

import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FreeV6Onboarding {
  static const _key = 'freev6.onboardingSeen';

  Future<bool> shouldShow({required bool hasProfiles}) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_key) == true) return false;
    if (hasProfiles) {
      await complete();
      return false;
    }
    return true;
  }

  Future<void> complete() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_key, true)) {
      throw StateError('Could not save onboarding state');
    }
  }
}

class FreeV6Storage {
  const FreeV6Storage();

  static const _channel = MethodChannel('dev.freev6.mobile/storage');

  Future<String?> read() => _channel.invokeMethod<String>('read');

  Future<void> write(String credentials) =>
      _channel.invokeMethod<void>('write', credentials);

  Future<Map<String, dynamic>> network({bool probe = false}) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('network', {
              'probe': probe,
            }) ??
            {},
      );
}

class FreeV6Preparation {
  FreeV6Preparation(this.core, this.storage);

  final CoreHandlerInterface core;
  final FreeV6Storage storage;
  String? _pendingCredentials;
  bool _preparing = false;

  Future<String> prepare(List<String> campusTargets) async {
    if (_preparing) throw StateError('Flux6 preparation is already running');
    _preparing = true;
    try {
      var credentials = _pendingCredentials ?? await storage.read();
      if (credentials == null) {
        credentials =
            await core.invokeMethod(
                  method: CoreMethod.freeV6Register,
                  timeout: const Duration(seconds: 55),
                )
                as String;
        _pendingCredentials = credentials;
      }
      if (_pendingCredentials != null) {
        await storage.write(credentials);
        _pendingCredentials = null;
      }
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
