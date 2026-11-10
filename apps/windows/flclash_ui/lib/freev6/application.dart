import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/theme_manager.dart';
import 'package:fl_clash/manager/window_manager.dart'
    show WindowHeaderContainer;
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session.dart';
import 'lifecycle.dart';
import 'background.dart';

class FreeV6Prototype extends ConsumerWidget {
  const FreeV6Prototype({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.read(freev6SessionProvider);
    final model = session.model;
    ref.watch(
      freev6RevisionProvider.select(
        (_) => (
          model.preference('freev6-wallpaper'),
          model.preference('freev6-bg-mode'),
          model.preference('freev6-webgl-glass'),
          model.preference('reduce-motion'),
          model.runtime['backdrop'],
        ),
      ),
    );
    ref.listen(freev6RevisionProvider, (_, _) {
      final model = ref.read(freev6SessionProvider).model;
      final message = model.message;
      if (message == null || session.bannerQueued) return;
      session.bannerQueued = true;
      scheduleMicrotask(() {
        try {
          if (!context.mounted) return;
          final latest = model.message;
          model.dismissMessage();
          if (latest != null) {
            dialogs.showBanner(latest, level: BannerLevel.warning);
          }
        } finally {
          session.bannerQueued = false;
        }
      });
    });
    final theme = ref.watch(themeSettingProvider);
    return PrismApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      title: 'FreeV6',
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        AppUiLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      themeMode: theme.themeMode,
      theme: watchAppTheme(ref, Brightness.light),
      darkTheme: watchAppTheme(ref, Brightness.dark),
      emojiFont: (family: FontFamily.twEmoji.value, pattern: emojiPattern),
      builder: (context, child) => ThemeManager(
        child: Column(
          children: [
            if (session.offline)
              ColoredBox(
                color: context.colorScheme.chromeSurface,
                child: SizedBox(
                  height: 24,
                  child: Center(
                    child: Text(
                      context.appLocalizations.freev6Offline,
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: WindowHeaderContainer(
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: model.preference('reduce-motion') == '1',
                  ),
                  child: FreeV6Background(model: model, child: child!),
                ),
              ),
            ),
          ],
        ),
      ),
      home: const FreeV6Lifecycle(child: HomePage()),
    );
  }
}
