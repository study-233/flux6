import 'package:flutter/material.dart';

import 'app/preview_app.dart';
import 'platform/windows_host.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.contains('--host-probe')) {
    const host = WindowsHost();
    try {
      final info = await host.describe();
      await host.finishProbe(info.platform == 'windows' && info.preview);
    } on Object {
      await host.finishProbe(false);
    }
    return;
  }
  runApp(const PreviewApplication());
}
