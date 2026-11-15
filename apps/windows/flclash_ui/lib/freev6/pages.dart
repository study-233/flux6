import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session.dart';
import 'forms.dart';
import 'updates.dart';
import 'licenses.dart';

class FreeV6ConfigurationView extends ConsumerWidget {
  const FreeV6ConfigurationView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = watchFreeV6(ref);
    final session = ref.read(freev6SessionProvider);
    final l = context.appLocalizations;
    Widget toggle(String key, String title) => ListItem.toggle(
      title: Text(title),
      value: model.setting(key),
      onChanged:
          model.busy || (key == 'cloudEnabled' && model.cloud['locked'] == true)
          ? null
          : (value) => unawaited(session.act('settings.save', {key: value})),
    );
    Widget urlImport({required bool cloud}) => ListItem(
      title: Text(cloud ? l.freev6Portal : l.freev6ImportUrl),
      leading: const GlyphIcon(AppGlyphs.add),
      onTap: model.busy || (cloud && model.cloud['locked'] == true)
          ? null
          : () => dialogs.showCommonDialog<bool>(
              child: FreeV6InputDialog(
                title: cloud ? l.freev6Portal : l.freev6Url,
                value: cloud
                    ? '${model.cloud['portalHost'] ?? model.settings['portalHost'] ?? ''}'
                    : '',
                validate: (value) {
                  final uri = Uri.tryParse(
                    cloud && !value.contains('://') ? 'https://$value' : value,
                  );
                  return uri != null &&
                          ['http', 'https'].contains(uri.scheme) &&
                          uri.host.isNotEmpty
                      ? null
                      : l.freev6InvalidUrl;
                },
                save: (value) => session.act(
                  cloud ? 'cloud.import' : 'chain.import',
                  {if (!cloud) 'url': value, if (cloud) 'portalHost': value},
                ),
              ),
            ),
    );
    return FreeV6SectionPage(
      title: l.freev6Configuration,
      sections: [
        generateSection(
          title: l.freev6Campus,
          items: [
            ListItem(
              title: Text(l.freev6CampusRules),
              leading: const GlyphIcon(AppGlyphs.rules),
              subtitle: Text(
                (model.settings['campusCidrs'] as List? ?? []).join(', '),
              ),
              onTap: model.busy
                  ? null
                  : () => dialogs.showCommonDialog<bool>(
                      child: FreeV6InputDialog(
                        title: l.freev6CampusRules,
                        value: (model.settings['campusCidrs'] as List? ?? [])
                            .join('\n'),
                        multiline: true,
                        save: (value) => session.act('settings.save', {
                          'campusCidrs': value
                              .split(RegExp(r'[,，\s]+'))
                              .where((v) => v.isNotEmpty)
                              .toList(),
                        }),
                      ),
                    ),
            ),
          ],
        ),
        generateSection(
          title: l.freev6Chain,
          items: [
            toggle('chainEnabled', l.freev6Chain),
            ListItem(
              title: Text(l.freev6Imported),
              trailing: Text('${model.chain['count'] ?? 0}'),
              subtitle: Text('${model.chain['source'] ?? ''}'),
            ),
            urlImport(cloud: false),
            ListItem(
              title: Text(l.freev6ImportFile),
              leading: const GlyphIcon(AppGlyphs.profiles),
              onTap: model.busy
                  ? null
                  : () async {
                      if (model.preview &&
                          await dialogs.showMessage(
                                title: l.freev6FileDemo,
                                message: TextSpan(text: l.freev6FileDetail),
                              ) !=
                              true) {
                        return;
                      }
                      await session.act('chain.file');
                    },
            ),
            if ((model.chain['count'] as num? ?? 0) > 0)
              ListItem(
                title: Text(l.freev6Clear),
                leading: const GlyphIcon(AppGlyphs.remove),
                onTap: model.busy
                    ? null
                    : () async {
                        if (await dialogs.showMessage(
                              title: l.freev6Clear,
                              message: TextSpan(text: l.freev6ClearDetail),
                            ) ==
                            true) {
                          await session.act('chain.clear');
                        }
                      },
              ),
          ],
        ),
        generateSection(
          title: l.freev6Cloud,
          footer: model.cloud['locked'] == true
              ? l.freev6CloudLocked
              : l.freev6CloudGate,
          items: [
            toggle('cloudEnabled', l.freev6Cloud),
            ListItem(
              title: Text(l.freev6Imported),
              trailing: Text('${model.cloud['count'] ?? 0}'),
              subtitle: Text('${model.cloud['portalHost'] ?? ''}'),
            ),
            urlImport(cloud: true),
            if ((model.cloud['count'] as num? ?? 0) > 0)
              ListItem(
                title: Text(l.freev6Clear),
                leading: const GlyphIcon(AppGlyphs.remove),
                onTap: model.busy
                    ? null
                    : () async {
                        if (await dialogs.showMessage(
                              title: l.freev6Clear,
                              message: TextSpan(text: l.freev6ClearDetail),
                            ) ==
                            true) {
                          await session.act('cloud.clear');
                        }
                      },
              ),
          ],
        ),
      ],
    );
  }
}

class FreeV6SettingsView extends ConsumerWidget {
  const FreeV6SettingsView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.appLocalizations;
    final model = watchFreeV6(ref);
    return FreeV6SectionPage(
      title: l.freev6Settings,
      sections: [
        generateSection(
          title: l.freev6Settings,
          items: [
            ListItem.open(
              title: Text(l.freev6General),
              leading: const GlyphIcon(AppGlyphs.devices),
              widget: const FreeV6GeneralView(),
            ),
            ListItem.open(
              title: Text(l.freev6Appearance),
              leading: const GlyphIcon(AppGlyphs.palette),
              widget: const FreeV6AppearanceView(),
            ),
            ListItem.open(
              title: Text(l.freev6Access),
              leading: const GlyphIcon(AppGlyphs.resources),
              widget: const FreeV6AccessView(),
            ),
            ListItem.open(
              title: Text(l.freev6Data),
              leading: const GlyphIcon(AppGlyphs.resources),
              widget: const FreeV6DataView(),
            ),
          ],
        ),
        generateSection(
          title: l.freev6About,
          items: [
            ListItem(
              title: Text(l.freev6Notices),
              leading: const GlyphIcon(AppGlyphs.logs),
              onTap: () => showFreeV6Notices(context, ref),
            ),
            ListItem.open(
              title: Text(l.freev6Update),
              leading: const GlyphIcon(AppGlyphs.refresh),
              widget: const FreeV6UpdatesView(),
            ),
            ListItem.open(
              title: Text(l.freev6Licenses),
              leading: const GlyphIcon(AppGlyphs.profiles),
              widget: const FreeV6LicensesView(),
            ),
            for (final (label, path) in [
              (l.freev6Repository, ''),
              (l.freev6Feedback, '/issues'),
              (l.freev6Agreement, '/blob/main/docs/agreement.md'),
              (l.freev6Privacy, '/blob/main/docs/privacy.md'),
            ])
              ListItem(
                title: Text(label),
                onTap: () => ref.read(freev6SessionProvider).act(
                  'external.open',
                  {'url': 'https://github.com/study-233/free-v6$path'},
                ),
              ),
            ListItem(
              title: Text(l.freev6Refresh),
              leading: const GlyphIcon(AppGlyphs.refresh),
              onTap: () => ref.read(freev6SessionProvider).act('refresh'),
            ),
            ListItem(
              title: const Text('FreeV6'),
              subtitle: Text('${model.runtime['appVersion'] ?? '0.5.3'}'),
              trailing: const Text('FlClash 0.9.3'),
            ),
          ],
        ),
      ],
    );
  }
}

class FreeV6GeneralView extends ConsumerWidget {
  const FreeV6GeneralView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref);
    final l = context.appLocalizations;
    Widget toggle(String key, String title, Glyph glyph) => ListItem.toggle(
      title: Text(title),
      leading: GlyphIcon(glyph),
      value: m.setting(key),
      onChanged: m.busy
          ? null
          : (value) => unawaited(
              ref.read(freev6SessionProvider).act('settings.save', {
                key: value,
              }),
            ),
    );
    return FreeV6SectionPage(
      title: l.freev6General,
      sections: [
        generateSection(
          footer: ref.read(freev6SessionProvider).offline
              ? l.freev6PreviewAction
              : null,
          items: [
            toggle('autoStart', l.freev6AutoStart, AppGlyphs.status),
            toggle('silentStart', l.freev6Silent, AppGlyphs.devices),
            toggle('autoRunProxy', l.freev6AutoRun, AppGlyphs.status),
            toggle('hotkeyEnabled', l.freev6F6, AppGlyphs.keyboard),
            toggle('hotspotShare', l.freev6Hotspot, AppGlyphs.wifi),
            toggle('devMode', l.freev6Developer, AppGlyphs.code),
          ],
        ),
      ],
    );
  }
}

class FreeV6AppearanceView extends ConsumerWidget {
  const FreeV6AppearanceView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    final session = ref.read(freev6SessionProvider);
    Future<void> pref(String key, String value) async {
      await session.act('preferences.set', {'key': key, 'value': value});
    }

    Widget toggle(String key, String title, {bool defaultOn = false}) =>
        ListItem.toggle(
          title: Text(title),
          value: m.preference(key, defaultOn ? '1' : '0') == '1',
          onChanged: (value) {
            unawaited(pref(key, value ? '1' : '0'));
          },
        );
    final themes = {
      'system': l.freev6System,
      'light': l.freev6Light,
      'dark': l.freev6Dark,
    };
    final backgrounds = {
      'default': l.freev6Default,
      'mica': l.freev6Mica,
      'acrylic': l.freev6Acrylic,
      'wallpaper': l.freev6Wallpaper,
    };
    return FreeV6SectionPage(
      title: l.freev6Appearance,
      sections: [
        generateSection(
          items: [
            ListItem.options(
              title: Text(l.freev6Theme),
              leading: const GlyphIcon(AppGlyphs.palette),
              options: themes.keys.toList(),
              value: m.preference('freev6-theme', 'system'),
              textBuilder: (v) => themes[v]!,
              onChanged: (value) {
                unawaited(pref('freev6-theme', value));
              },
            ),
            toggle('freev6-dynamic-color', l.freev6Dynamic),
            toggle('freev6-pure-black', l.freev6Black),
            ListItem.options(
              title: Text(l.freev6Background),
              options: backgrounds.keys.toList(),
              value: m.preference('freev6-bg-mode', 'default'),
              textBuilder: (v) => backgrounds[v]!,
              onChanged: (v) => unawaited(pref('freev6-bg-mode', v)),
            ),
            ListItem(
              title: Text(l.freev6ChooseWallpaper),
              leading: const GlyphIcon(AppGlyphs.palette),
              onTap: () async {
                final success = await session.act('wallpaper.choose');
                if (success && context.mounted) {
                  await dialogs.showMessage(
                    message: TextSpan(text: l.freev6Completed),
                  );
                }
              },
            ),
            ListItem(
              title: Text(l.freev6ClearWallpaper),
              leading: const GlyphIcon(AppGlyphs.remove),
              onTap: () => unawaited(session.act('wallpaper.clear')),
            ),
            toggle('freev6-webgl-glass', l.freev6Glass, defaultOn: true),
            toggle('reduce-motion', l.freev6Motion),
          ],
        ),
      ],
    );
  }
}

class FreeV6AccessView extends ConsumerWidget {
  const FreeV6AccessView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    final session = ref.read(freev6SessionProvider);
    return FreeV6SectionPage(
      title: l.freev6Access,
      sections: [
        generateSection(
          footer: ref.read(freev6SessionProvider).offline
              ? l.freev6PreviewAction
              : null,
          items: [
            ListItem(
              title: Text(l.freev6Core),
              subtitle: Text(
                m.runtime['present'] == true ? l.freev6Ready : l.freev6Missing,
              ),
              leading: const GlyphIcon(AppGlyphs.resources),
            ),
            ListItem(
              title: Text(l.freev6Download),
              leading: const GlyphIcon(AppGlyphs.cloudDownload),
              onTap: m.busy || m.connected
                  ? null
                  : () => unawaited(session.act('core.download')),
              subtitle: Text(
                m.coreDownload.isEmpty
                    ? ''
                    : '${m.coreDownload['state'] ?? ''} · ${m.coreDownload['done'] ?? 0} / ${m.coreDownload['total'] ?? '?'}',
              ),
            ),
            ListItem(
              title: const Text('WARP'),
              subtitle: Text(
                m.runtime['warpRegistered'] == true
                    ? l.freev6Ready
                    : l.freev6Missing,
              ),
              leading: const GlyphIcon(AppGlyphs.verified),
            ),
            ListItem(
              title: Text(l.freev6Register),
              leading: const GlyphIcon(AppGlyphs.refresh),
              onTap: m.busy || m.connected
                  ? null
                  : () => unawaited(session.act('warp.register')),
            ),
          ],
        ),
      ],
    );
  }
}

class FreeV6DataView extends ConsumerWidget {
  const FreeV6DataView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.appLocalizations;
    final session = ref.read(freev6SessionProvider);
    final model = watchFreeV6(ref);
    return FreeV6SectionPage(
      title: l.freev6Data,
      sections: [
        generateSection(
          footer: ref.read(freev6SessionProvider).offline
              ? l.freev6PreviewAction
              : null,
          items: [
            ListItem(
              title: Text(l.freev6ClearLogs),
              leading: const GlyphIcon(AppGlyphs.logs),
              onTap: model.busy ? null : () => session.act('logs.clear'),
            ),
            ListItem(
              title: Text(l.freev6Export),
              leading: const GlyphIcon(AppGlyphs.export),
              onTap: () async {
                final success = await session.act('preferences.export');
                if (success && context.mounted) {
                  await dialogs.showMessage(
                    message: TextSpan(text: l.freev6Completed),
                  );
                }
              },
            ),
            ListItem(
              title: Text(l.freev6Restore),
              leading: const GlyphIcon(AppGlyphs.upload),
              onTap: () async {
                final success = await session.act('preferences.import');
                if (success && context.mounted) {
                  await dialogs.showMessage(
                    message: TextSpan(text: l.freev6Completed),
                  );
                }
              },
            ),
            ListItem(
              title: Text(l.freev6Reset),
              leading: const GlyphIcon(AppGlyphs.reset),
              onTap: () async {
                if (await dialogs.showMessage(
                      title: l.freev6Reset,
                      message: TextSpan(text: l.freev6ResetDetail),
                    ) ==
                    true) {
                  await session.act('settings.reset');
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class FreeV6SectionPage extends StatelessWidget {
  const FreeV6SectionPage({
    super.key,
    required this.title,
    required this.sections,
  });
  final String title;
  final List<Widget> sections;
  @override
  Widget build(BuildContext context) => Scaffold(
    title: title,
    body: ListView(
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24),
      children: sections,
    ),
  );
}

Future<void> showFreeV6Notices(BuildContext context, WidgetRef ref) async {
  final session = ref.read(freev6SessionProvider);
  for (final notice in session.model.notices) {
    await dialogs.showMessage(
      title: '${notice['title']}',
      message: TextSpan(text: '${notice['body'] ?? notice['content'] ?? ''}'),
    );
    if (notice['link'] case final String url) {
      if (context.mounted &&
          await dialogs.showMessage(
                title:
                    '${notice['linkText'] ?? context.appLocalizations.freev6Details}',
                message: TextSpan(text: url),
              ) ==
              true) {
        await session.act('external.open', {'url': url});
      }
    }
    await session.act('notice.read', {'id': notice['id']});
  }
}

/// Mobile dashboard columns give cards an unbounded vertical constraint.
class FreeV6AdaptiveCard extends StatelessWidget {
  const FreeV6AdaptiveCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.hasBoundedHeight
        ? child
        : SizedBox(
            height: 176 * MediaQuery.textScalerOf(context).scale(1),
            child: child,
          ),
  );
}

class FreeV6UsageCard extends ConsumerWidget {
  const FreeV6UsageCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardCardHeader(glyph: AppGlyphs.speed, title: l.freev6Usage),
          const Spacer(),
          Text(
            (m.usageUpload + m.usageDownload).traffic.show,
            style: DashboardText.figure(context, AppTextStyle.title1),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => m.setMonthly(!m.monthly),
            child: Text(
              m.monthly ? l.freev6Month : l.freev6Total,
              style: DashboardText.label(context),
            ),
          ),
        ],
      ),
    );
  }
}

class FreeV6RuntimeCard extends ConsumerWidget {
  const FreeV6RuntimeCard({super.key, this.hotspot = false});
  final bool hotspot;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    return DashboardCard(
      onTap: () =>
          ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.tools),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardCardHeader(
            glyph: hotspot ? AppGlyphs.wifi : AppGlyphs.resources,
            title: hotspot ? l.freev6Hotspot : l.freev6Access,
          ),
          const Spacer(),
          Text(
            hotspot
                ? (m.setting('hotspotShare')
                      ? l.freev6Enabled
                      : l.freev6Disabled)
                : (m.runtime['warpRegistered'] == true
                      ? l.freev6Ready
                      : l.freev6Missing),
            style: AppTextStyle.headline.of(context),
          ),
          const SizedBox(height: 6),
          Text(
            hotspot ? l.freev6General : 'WARP · MASQUE',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DashboardText.label(context),
          ),
        ],
      ),
    );
  }
}

class FreeV6ConnectionTile extends ConsumerWidget {
  const FreeV6ConnectionTile({super.key, this.settings = false});
  final bool settings;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    return DashboardCard(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: () => ref
          .read(currentPageLabelProvider.notifier)
          .toPage(settings ? PageLabel.tools : PageLabel.proxies),
      child: Row(
        children: [
          GlyphIcon(settings ? AppGlyphs.tools : AppGlyphs.proxies),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              settings ? l.freev6Settings : accessGroup,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.subheadline.of(context),
            ),
          ),
          if (!settings)
            Flexible(
              child: Text(
                m.displayNode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardText.label(context),
              ),
            ),
          const GlyphIcon(AppGlyphs.chevronForward, size: 16),
        ],
      ),
    );
  }
}

class FreeV6ActivityCard extends ConsumerWidget {
  const FreeV6ActivityCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref), l = context.appLocalizations;
    return DashboardCard(
      onTap: () =>
          ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.logs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardCardHeader(glyph: AppGlyphs.logs, title: l.freev6Activity),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (final log in m.logs.take(6))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(
                      log.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: DashboardText.label(context),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class FreeV6ProfileCard extends ConsumerWidget {
  const FreeV6ProfileCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref);
    return DashboardCard(
      onTap: () => ref
          .read(currentPageLabelProvider.notifier)
          .toPage(PageLabel.profiles),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.profiles,
            title: context.appLocalizations.freev6Configuration,
          ),
          const Spacer(),
          Text(
            m.profileName,
            style: AppTextStyle.headline.of(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            context.appLocalizations.freev6Campus,
            style: DashboardText.label(context),
          ),
        ],
      ),
    );
  }
}

class FreeV6ExitLabel extends ConsumerWidget {
  const FreeV6ExitLabel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = watchFreeV6(ref);
    return Row(
      spacing: 12,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            color: DashboardColors.of(context).tone,
            shape: AppShape.sm,
          ),
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: GlyphIcon(AppGlyphs.proxies),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                m.displayNode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.title2.of(context, emphasized: true),
              ),
              Text(
                m.profileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardText.label(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
