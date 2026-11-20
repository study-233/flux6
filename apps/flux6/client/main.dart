import 'dart:io';

import 'android_main.dart' as android;
import 'mac_host/live_main.dart' as mac;
import 'mac_navigation.dart';

Future<void> main(List<String> arguments) async {
  if (Platform.isMacOS) {
    await mac.runMacHost(
      arguments,
      navigation: MacNavigation.new,
      nodeGroups: MacNodeGroups.new,
    );
  } else if (Platform.isAndroid) {
    android.main(arguments);
  } else {
    throw UnsupportedError('Expected the Android or macOS client');
  }
}
