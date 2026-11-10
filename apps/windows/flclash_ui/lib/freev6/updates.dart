import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages.dart' show FreeV6SectionPage;
import 'session.dart';

class FreeV6UpdatesView extends ConsumerWidget {
  const FreeV6UpdatesView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    final session = ref.read(freev6SessionProvider);
    return FreeV6SectionPage(
      title: l.freev6Update,
      sections: [
        generateSection(
          footer: session.offline ? l.freev6PreviewAction : null,
          items: [
            ListItem(
              title: Text(l.freev6Update),
              leading: const GlyphIcon(AppGlyphs.refresh),
              onTap: m.pending('update.check') || m.busy
                  ? null
                  : () => unawaited(session.act('update.check')),
            ),
            if (m.update['available'] == true) ...[
              ListItem(
                title: Text('${l.freev6InstallUpdate} ${m.update['version']}'),
                leading: const GlyphIcon(AppGlyphs.cloudDownload),
                onTap: m.busy
                    ? null
                    : () async {
                        if (await dialogs.showMessage(
                              title: l.freev6InstallUpdate,
                              message: TextSpan(
                                text: session.offline
                                    ? l.freev6PreviewAction
                                    : l.freev6InstallDetail,
                              ),
                            ) ==
                            true) {
                          await session.act('update.install');
                        }
                      },
              ),
              ListItem(
                title: Text(l.freev6SkipVersion),
                onTap: m.busy
                    ? null
                    : () => unawaited(session.act('update.skip')),
              ),
            ],
            if (m.update.isNotEmpty)
              ListItem(
                title: Text(
                  m.pending('update.install') || m.pending('update.check')
                      ? l.freev6Working
                      : m.update['available'] == true
                      ? '${m.update['version']}'
                      : l.freev6UpdateChecked,
                ),
                subtitle: Text(
                  '${m.update['notes'] ?? ''}\n${m.update['state'] ?? ''} ${m.update['done'] ?? ''} ${m.update['total'] == null ? '' : '/ ${m.update['total']}'}'
                      .trim(),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
