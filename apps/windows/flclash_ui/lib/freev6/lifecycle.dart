import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:freev6_windows/features/window_background.dart'
    show halloweenEnabled, halloweenDateKey;

import 'session.dart';

class FreeV6Lifecycle extends ConsumerStatefulWidget {
  const FreeV6Lifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<FreeV6Lifecycle> createState() => _FreeV6LifecycleState();
}

class _FreeV6LifecycleState extends ConsumerState<FreeV6Lifecycle> {
  StreamSubscription<String>? _events;
  bool _quitting = false;
  @override
  void initState() {
    super.initState();
    final session = ref.read(freev6SessionProvider);
    _events = session.model.events.listen((event) {
      if (event == 'exitRequested') unawaited(_quit());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !session.backend ||
          session.model.preference('freev6-guide-done') == '1') {
        return;
      }
      final l = context.appLocalizations;
      await dialogs.showAlert(
        title: l.freev6Welcome,
        message: TextSpan(text: l.freev6Guide),
      );
      if (mounted) {
        await session.act('preferences.set', {
          'key': 'freev6-guide-done',
          'value': '1',
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final m = session.model;
      final now = DateTime.now();
      if (!mounted ||
          !halloweenEnabled(now, m.preference('freev6-halloween-force')) ||
          m.preference('freev6-halloween-greeted') == halloweenDateKey(now)) {
        return;
      }
      dialogs.showBanner(context.appLocalizations.freev6Halloween);
      await session.act('preferences.set', {
        'key': 'freev6-halloween-greeted',
        'value': halloweenDateKey(now),
      });
    });
  }

  Future<void> _quit() async {
    final model = ref.read(freev6SessionProvider).model;
    if (_quitting || model.busy) return;
    _quitting = true;
    try {
      final l = context.appLocalizations;
      if (!model.connected ||
          await dialogs.showMessage(
                title: l.freev6Quit,
                message: TextSpan(text: l.freev6QuitDetail),
              ) ==
              true) {
        if (mounted) await ref.read(systemActionProvider.notifier).handleExit();
      }
    } finally {
      _quitting = false;
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = ref.read(freev6SessionProvider).model;
    ref.watch(
      freev6RevisionProvider.select(
        (_) => model.preference('freev6-halloween-force'),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        for (final (i, key) in [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit5,
        ].indexed)
          SingleActivator(key, control: true): () => ref
              .read(currentPageLabelProvider.notifier)
              .toPage(
                [
                  PageLabel.dashboard,
                  PageLabel.proxies,
                  PageLabel.profiles,
                  PageLabel.logs,
                  PageLabel.tools,
                ][i],
              ),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.tools),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () =>
            unawaited(ref.read(freev6SessionProvider).act('refresh')),
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true): () =>
            unawaited(_quit()),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            widget.child,
            if (halloweenEnabled(
              DateTime.now(),
              model.preference('freev6-halloween-force'),
            ))
              Positioned(
                top: 12,
                right: 72,
                child: TextButton(
                  onPressed: () => dialogs.showAlert(
                    message: TextSpan(
                      text: context.appLocalizations.freev6Halloween,
                    ),
                  ),
                  child: const Text('🎃'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
