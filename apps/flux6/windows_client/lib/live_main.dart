import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart'
    show IoTransport, HelperApi, HelperCredentials, object;
import 'package:freev6_windows/platform/preferences_store.dart';
import 'package:freev6_windows/platform/windows_host.dart';
import 'package:window/window.dart';

import 'freev6/application.dart';
import 'freev6/navigation.dart';
import 'freev6/session.dart';

Future<void> main(List<String> arguments) async {
  if (safeModeBuild ||
      const bool.fromEnvironment('FREEV6_OFFLINE') ||
      !const bool.fromEnvironment('FREEV6_BACKEND')) {
    throw StateError('Live entry requires an explicit backend build');
  }
  WidgetsFlutterBinding.ensureInitialized();
  await desktopWindow.ensureInitialized();
  await desktopWindow.setTitleBarStyle(TitleBarStyle.hidden);
  await desktopWindow.setMinimumSize(const Size(720, 480));
  await desktopWindow.setSize(const Size(1280, 800));
  runApp(const FreeV6BackendBootstrap());
}

class FreeV6BackendBootstrap extends StatefulWidget {
  const FreeV6BackendBootstrap({super.key});
  @override
  State<FreeV6BackendBootstrap> createState() => _FreeV6BackendBootstrapState();
}

class _FreeV6BackendBootstrapState extends State<FreeV6BackendBootstrap> {
  final host = WindowsHost();
  FreeV6Session? session;
  Object? error;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    unawaited(initialize());
  }

  Future<void> initialize() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    LiveModel? candidate;
    try {
      if ((await host.describe()).preview) {
        throw StateError('真实后端入口需要 live 原生宿主');
      }
      final bootstrap = object(await host.call('bootstrap'));
      final transport = IoTransport();
      candidate = LiveModel(
        helper: HelperApi(
          transport,
          () async => HelperCredentials.decode(await host.call('bootstrap')),
        ),
        transport: transport,
        host: host,
        store: FilePreferences(
          File(
            '${bootstrap['root']}${Platform.pathSeparator}state${Platform.pathSeparator}flutter-ui.json',
          ),
        ),
        version: bootstrap['appVersion'] as String,
      );
      await candidate.initialize();
      if (!mounted) {
        candidate.dispose();
        return;
      }
      navigationPort = FreeV6Navigation();
      windowPort = window;
      setState(() {
        session = FreeV6Session(candidate!, backend: true, offline: false);
        loading = false;
      });
    } catch (failure) {
      candidate?.dispose();
      if (mounted) {
        setState(() {
          error = failure;
          loading = false;
        });
      }
      try {
        await host.call('window.show');
      } catch (_) {
        /* mismatched host */
      }
    }
  }

  Future<void> quit() async {
    final transport = IoTransport();
    try {
      final api = HelperApi(
        transport,
        () async => HelperCredentials.decode(await host.call('bootstrap')),
      );
      final stopped = await api.call(
        '/proxy/stop',
        method: 'POST',
        timeout: const Duration(seconds: 90),
      );
      if (stopped['running'] != false) throw StateError('无法确认连接停止，请重试');
      await host.call('app.quit');
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      transport.close();
    }
  }

  @override
  void dispose() {
    session?.dispose();
    host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = session;
    if (ready != null) {
      return UncontrolledProviderScope(
        container: ready.container,
        child: const FreeV6Prototype(),
      );
    }
    return PrismApp(
      title: 'Flux6',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: seededColorScheme(
          seedColor: const Color(defaultPrimaryColor),
          brightness: Brightness.light,
          style: ColorStyle.vivid,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: seededColorScheme(
          seedColor: const Color(defaultPrimaryColor),
          brightness: Brightness.dark,
          style: ColorStyle.vivid,
        ),
      ),
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        AppUiLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      home: FreeV6StartupView(
        loading: loading,
        error: error,
        retry: initialize,
        quit: quit,
      ),
    );
  }
}

class FreeV6StartupView extends StatelessWidget {
  const FreeV6StartupView({
    super.key,
    required this.loading,
    this.error,
    required this.retry,
    required this.quit,
  });
  final bool loading;
  final Object? error;
  final VoidCallback retry, quit;

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return Surface(
      color: SurfaceLevel.page.colorOf(context.colorScheme),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GlyphIcon(AppGlyphs.proxies, size: 40),
                  const SizedBox(height: 16),
                  Text(
                    'Flux6',
                    style: AppTextStyle.title1.of(context, emphasized: true),
                  ),
                  const SizedBox(height: 20),
                  if (loading) ...[
                    const ActivityIndicator(),
                    const SizedBox(height: 12),
                    Text(
                      l.freev6Starting,
                      style: AppTextStyle.subheadline.of(context).toLight,
                    ),
                  ] else ...[
                    Text(l.freev6StartFailed, textAlign: TextAlign.center),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '$error',
                        textAlign: TextAlign.center,
                        style: AppTextStyle.footnote.of(context).toLight,
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextButton(onPressed: retry, child: Text(l.freev6Retry)),
                    TextButton(onPressed: quit, child: Text(l.freev6Quit)),
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
