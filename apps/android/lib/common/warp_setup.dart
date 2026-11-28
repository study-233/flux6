import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/freev6.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum WarpSetupStatus {
  idle,
  preparing,
  ready,
  storageFailed,
  registrationFailed,
  profileFailed,
}

final warpSetupProvider = NotifierProvider<WarpSetup, WarpSetupStatus>(
  WarpSetup.new,
);

class WarpSetup extends Notifier<WarpSetupStatus> {
  late final _preparation = FreeV6Preparation(
    ref.read(coreHandlerProvider),
    const FreeV6Storage(),
  );

  @override
  WarpSetupStatus build() => WarpSetupStatus.idle;

  Future<void> prepare({bool automatic = false}) async {
    if (state == WarpSetupStatus.preparing) return;
    state = WarpSetupStatus.preparing;
    var stage = WarpPreparationStep.storage;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (automatic && prefs.getBool('flux6.warp.complete') == true) {
        state = WarpSetupStatus.idle;
        return;
      }
      final profile = Profile.normal(label: 'Flux6 WARP');
      final id = prefs.getInt('flux6.warp.profile') ?? profile.id;
      if (!await prefs.setInt('flux6.warp.profile', id)) {
        throw StateError('profile id');
      }
      final generated = await _preparation.prepare(
        const [],
        onStep: (next) => stage = next,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(await encodeYamlTask(jsonDecode(generated))),
      );
      final core = ref.read(coreHandlerProvider);
      final prepared = await profile
          .copyWith(id: id, autoUpdate: false)
          .saveFile(
            bytes,
            validate: (path, key) => core.validateProfile(path, key),
          );
      await ref.read(profilesProvider.notifier).putAndWait(prepared);
      if (system.isAndroid) {
        ref
            .read(vpnSettingProvider.notifier)
            .update((value) => value.copyWith(ipv6: true));
      }
      ref.read(currentProfileIdProvider.notifier).value = id;
      if (!await ref
              .read(setupActionProvider.notifier)
              .applyProfile(force: true) ||
          !await preferences.saveConfig(ref.read(configProvider)) ||
          !await prefs.setBool('flux6.warp.complete', true)) {
        throw StateError('profile not applied');
      }
      state = WarpSetupStatus.ready;
    } catch (_) {
      state = switch (stage) {
        WarpPreparationStep.storage => WarpSetupStatus.storageFailed,
        WarpPreparationStep.registration => WarpSetupStatus.registrationFailed,
        WarpPreparationStep.profile => WarpSetupStatus.profileFailed,
      };
    }
  }
}
