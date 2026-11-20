import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/freev6.dart';
import 'package:fl_clash/core/desktop/launcher.dart';
import 'package:fl_clash/core/desktop/lifecycle.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/desktop/rpc_client.dart';
import 'package:fl_clash/core/desktop/transport.dart';
import 'package:fl_clash/core/service.dart';
import 'package:fl_clash/models/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rust_api/rust_api.dart';

class _LocalLauncher implements DesktopCoreLauncherResolver {
  @override
  Future<CoreProcessLauncher> resolve() async => DirectCoreLauncher(
    corePath: p.absolute(
      'libclash',
      Platform.operatingSystem,
      Platform.isWindows ? 'FlClashCore.exe' : 'FlClashCore',
    ),
  );
}

class _SavedFixture extends FreeV6Storage {
  final String credentials;
  _SavedFixture(this.credentials);

  @override
  Future<String?> read() async => credentials;

  @override
  Future<void> write(String credentials) async =>
      fail('Unexpected registration');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'desktop core renders and validates the saved Flux6 account over IPC',
    () async {
      await RustLib.init();
      final dir = await Directory.systemTemp.createTemp('flux6-core-');
      addTearDown(() => dir.delete(recursive: true));
      final address = Platform.isWindows
          ? r'\\.\pipe\' + p.basename(dir.path)
          : p.join(dir.path, 'core.sock');
      final lifecycle = DesktopCoreLifecycle(
        transportFactory: () => IpcCoreTransport(address: address),
        launcherResolver: _LocalLauncher(),
        verifyPeerPid: Platform.isWindows,
      );
      final core = CoreService.forTesting(
        lifecycle: lifecycle,
        rpcClient: CoreRpcClient(lifecycle.transport),
      );
      addTearDown(core.close);
      await core.start();
      expect(lifecycle.state, isA<DesktopCoreRunning>());
      await core.init(InitParams(homeDir: dir.path, version: 1));
      final fixture = jsonDecode(
        await File('../../shared/fixtures/warp-credential.json').readAsString(),
      ) as Map;
      final preparation = FreeV6Preparation(
        core,
        _SavedFixture(jsonEncode(fixture['device'])),
      );
      final profile =
          jsonDecode(await preparation.prepare(['campus.example.edu'])) as Map;
      final proxies = (profile['proxies'] as List).cast<Map<String, dynamic>>();
      expect(proxies, hasLength(28));
      expect(await core.validateProxies(proxies), isEmpty);
      expect(
        profile['rules'],
        contains('DOMAIN-SUFFIX,campus.example.edu,DIRECT'),
      );
      final file = File(p.join(dir.path, 'profile.json'));
      await file.writeAsString(jsonEncode(profile));
      final outbounds = await core.getProfileOutbounds(file.path);
      expect(
        (outbounds['proxies'] as List).map((e) => e['name']),
        proxies.map((proxy) => proxy['name']),
      );
      await core.stop();
      expect(lifecycle.state, isA<DesktopCoreIdle>());
    },
  );
}
