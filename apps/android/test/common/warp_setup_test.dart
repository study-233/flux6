import 'dart:io';

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/warp_setup.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_profiles.dart';
import 'freev6_test.dart' show RecordingCore;

class _Core extends RecordingCore {
  @override
  Future<String?> validateConfig(String path) async {
    expect(await File(path).readAsString(), contains('proxies:'));
    return null;
  }
}

class _Profiles extends TestProfiles {
  @override
  Future<void> putAndWait(Profile profile) async => put(profile);
}

class _Setup extends SetupAction {
  bool applied = false;
  @override
  void build() {}
  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async => applied;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'first launch retries the same profile and skips completed setup on relaunch',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'flux6-first-start',
      );
      addTearDown(() => directory.delete(recursive: true));
      await useAppPaths(directory);
      SharedPreferences.setMockInitialValues({});
      await preferences.rebind();
      final core = _Core();
      final setup = _Setup();
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          profilesProvider.overrideWith(_Profiles.new),
          setupActionProvider.overrideWith(() => setup),
        ],
      );
      addTearDown(container.dispose);
      String? stored;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('dev.freev6.mobile/storage');
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'read':
            return stored;
          case 'write':
            stored = call.arguments as String;
            return null;
          case 'protect':
            return call.arguments;
          case 'unprotect':
            return call.arguments;
          default:
            throw StateError(call.method);
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final action = container.read(warpSetupProvider.notifier);
      await action.prepare(automatic: true);
      expect(container.read(warpSetupProvider), WarpSetupStatus.profileFailed);
      final id = container.read(profilesProvider).single.id;
      setup.applied = true;
      await action.prepare(automatic: true);
      expect(container.read(warpSetupProvider), WarpSetupStatus.ready);
      expect(container.read(profilesProvider).single.id, id);
      expect((await preferences.getConfig())?.currentProfileId, id);
      await action.prepare(automatic: true);
      expect(core.registrations, 1);
      expect(core.profiles.length, 2);
    },
  );
}
