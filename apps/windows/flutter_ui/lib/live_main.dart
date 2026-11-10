import 'dart:io';

import 'package:flutter/material.dart';

import 'app/client_app.dart';
import 'app/licenses.dart';
import 'app/live_model.dart';
import 'backend/api.dart';
import 'platform/preferences_store.dart';
import 'platform/windows_host.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerComponentLicenses();
  final host = WindowsHost();
  if (arguments.contains('--host-probe')) {
    try {
      final info = await host.describe();
      await host.finishProbe(!info.preview);
    } catch (_) {
      await host.finishProbe(false);
    }
    return;
  }
  runApp(_Bootstrap(host: host));
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.host});
  final WindowsHost host;
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  LiveModel? model;
  Object? error;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    setState(() {
      loading = true;
      error = null;
    });
    LiveModel? candidate;
    try {
      final info = await widget.host.describe();
      if (info.preview) throw const FormatException('正式入口需要 live 原生宿主，请使用构建脚本');
      final bootstrap = object(await widget.host.call('bootstrap'));
      final transport = IoTransport();
      final helper = HelperApi(
        transport,
        () async =>
            HelperCredentials.decode(await widget.host.call('bootstrap')),
      );
      final root = bootstrap['root'] as String;
      candidate = LiveModel(
        helper: helper,
        transport: transport,
        host: widget.host,
        store: FilePreferences(
          File(
            '$root${Platform.pathSeparator}state${Platform.pathSeparator}flutter-ui.json',
          ),
        ),
        version: bootstrap['appVersion'] as String,
      );
      await candidate.initialize();
      if (!mounted) {
        candidate.dispose();
        return;
      }
      setState(() {
        model = candidate;
        loading = false;
      });
    } catch (e) {
      // Keep the host alive for retry; initialization hasn't attached live UI.
      candidate?.dispose();
      if (mounted)
        setState(() {
          error = e;
          loading = false;
        });
      try {
        await widget.host.call('window.show');
      } catch (_) {
        /* mismatched preview host */
      }
    }
  }

  Future<void> quit() async {
    final transport = IoTransport();
    try {
      final helper = HelperApi(
        transport,
        () async =>
            HelperCredentials.decode(await widget.host.call('bootstrap')),
      );
      final stopped = await helper.call(
        '/proxy/stop',
        method: 'POST',
        timeout: const Duration(seconds: 90),
      );
      if (stopped['running'] != false) throw const ApiFailure('无法确认网络已停止');
      await widget.host.call('app.quit');
    } catch (e) {
      if (mounted) setState(() => error = '无法安全退出：$e');
    } finally {
      transport.close();
    }
  }

  @override
  void dispose() {
    model?.dispose();
    widget.host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (model case final LiveModel ready)
      return ClientApplication(model: ready);
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('FreeV6', style: TextStyle(fontSize: 28)),
                  const SizedBox(height: 24),
                  if (loading) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    const Text('正在连接本地组件…'),
                  ] else ...[
                    SelectableText('启动失败：$error'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: initialize,
                      child: const Text('重试'),
                    ),
                    TextButton(onPressed: quit, child: const Text('停止并退出')),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
