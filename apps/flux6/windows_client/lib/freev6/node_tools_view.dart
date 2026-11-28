import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart' show object;

import 'session.dart';

class FreeV6NodesView extends ConsumerWidget {
  const FreeV6NodesView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ProxiesView(
      extraActions: [
        IconButtonData(
          glyph: AppGlyphs.speed,
          tooltip: context.appLocalizations.freev6NodeTools,
          onPressed: () => showSnapSheet(
            context,
            builder: (_, _) => const FreeV6NodeToolsView(),
          ),
        ),
      ],
    );
  }
}

class FreeV6NodeToolsView extends ConsumerStatefulWidget {
  const FreeV6NodeToolsView({super.key});
  @override
  ConsumerState<FreeV6NodeToolsView> createState() => _NodeToolsState();
}

class _NodeToolsState extends ConsumerState<FreeV6NodeToolsView> {
  bool sortBySpeed = false;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    final model = ref.read(freev6SessionProvider).model;
    if (model is LiveModel) model.nodeTools.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final model = watchFreeV6(ref), l = context.appLocalizations;
    final session = ref.read(freev6SessionProvider);
    if (model is! LiveModel) return Center(child: Text(l.freev6Offline));
    final tools = model.nodeTools;
    final nodes = [...model.nodes];
    double speed(String node) =>
        (tools.results['${tools.streams}/$node']?['bytesPerSecond'] as num? ??
                -1)
            .toDouble();
    if (sortBySpeed) nodes.sort((a, b) => speed(b).compareTo(speed(a)));
    final samples = (tools.quality['samples'] as List? ?? [])
        .map(object)
        .toList();
    final switches = (tools.quality['switches'] as List? ?? [])
        .map(object)
        .toList();
    final automatic = tools.pinned.isEmpty;
    final ready = model.canSelectNode && tools.state['profile'] != null;
    return Scaffold(
      title: l.freev6NodeTools,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 24),
        children: [
          SegmentedControl<int>(
            segments: [
              (0, l.freev6Policy),
              (1, l.freev6SpeedTest),
              (2, l.freev6Records),
            ],
            value: tab,
            onChanged: (value) => setState(() => tab = value),
          ),
          if (tab == 0) ...[
            generateSection(
              title: session.group,
              footer: l.freev6PolicyHint,
              items: [
                ListItem(
                  leading: GlyphIcon(
                    automatic ? AppGlyphs.shuffle : AppGlyphs.pin,
                  ),
                  title: Text(automatic ? l.freev6Automatic : l.freev6Pinned),
                  subtitle: Text(
                    !model.connected
                        ? l.freev6AutoConnect
                        : automatic
                        ? l.freev6AutoHint
                        : tools.pinned,
                  ),
                  trailing: tools.selecting
                      ? const ActivityIndicator()
                      : !automatic
                      ? TextButton(
                          onPressed: ready
                              ? () => session.inGroup(session.group, () async {
                                  await session.act('node.auto');
                                })
                              : null,
                          child: Text(l.freev6ReturnAuto),
                        )
                      : null,
                ),
                if (automatic && tools.state['poolSize'] is num)
                  if (ready)
                    ListItem<int>.options(
                      title: Text(l.freev6PoolSize),
                      subtitle: Text(l.freev6PoolHint),
                      options: const [2, 4, 8],
                      value: (tools.state['poolSize'] as num).toInt(),
                      textBuilder: l.freev6PoolCount,
                      onChanged: (value) =>
                          session.inGroup(session.group, () async {
                            await session.act('node.auto', {'poolSize': value});
                          }),
                    )
                  else
                    ListItem(
                      title: Text(l.freev6PoolSize),
                      trailing: Text(
                        l.freev6PoolCount(
                          (tools.state['poolSize'] as num).toInt(),
                        ),
                      ),
                    ),
                if (tools.error?.isNotEmpty == true)
                  ListItem(
                    title: Text(tools.error!),
                    trailing: const GlyphIcon(AppGlyphs.refresh),
                    onTap: tools.refresh,
                  ),
              ],
            ),
            if (model.connected && automatic && tools.activeNodes.isNotEmpty)
              generateSection(
                title: l.freev6ActiveNodes,
                items: [
                  for (final node in tools.activeNodes)
                    ListItem(
                      title: Text(node),
                      leading: const GlyphIcon(AppGlyphs.proxies),
                    ),
                ],
              ),
          ],
          if (tab == 1)
            generateSection(
              title: l.freev6SpeedTest,
              footer: l.freev6DownloadLimit,
              items: [
                ListItem<int>.options(
                  title: Text(l.freev6TestStreams),
                  options: const [1, 4],
                  value: tools.streams,
                  textBuilder: (v) => '$v',
                  onChanged: (v) {
                    if (!tools.downloading) setState(() => tools.streams = v);
                  },
                ),
                ListItem.toggle(
                  title: Text(l.freev6SortSpeed),
                  value: sortBySpeed,
                  onChanged: (v) => setState(() => sortBySpeed = v),
                ),
                ListItem(
                  title: Text(
                    tools.downloading
                        ? '${tools.completed}/${tools.total} · ${tools.measuring ?? ''}'
                        : l.freev6SpeedTest,
                  ),
                  trailing: TextButton(
                    onPressed: tools.downloading
                        ? () => session.act('nodes.cancel')
                        : model.connected
                        ? () => session.act('nodes.download')
                        : null,
                    child: Text(tools.downloading ? l.cancel : l.freev6TestAll),
                  ),
                ),
                for (final node in nodes)
                  ListItem(
                    title: Text(node),
                    subtitle: Text(
                      tools.results['${tools.streams}/$node']?['error']
                              ?.toString() ??
                          (speed(node) < 0
                              ? '—'
                              : '${(speed(node) / 1000000).toStringAsFixed(2)} MB/s'),
                    ),
                    trailing: TextButton(
                      onPressed: model.connected && !tools.downloading
                          ? () => session.act('nodes.download', {'name': node})
                          : null,
                      child: Text(l.freev6DownloadTest),
                    ),
                  ),
              ],
            ),
          if (tab == 2) ...[
            generateSection(
              title: l.freev6SwitchHistory,
              items: [
                if (switches.isEmpty) ListItem(title: Text(l.freev6NoRecords)),
                for (final item in switches.reversed.take(50))
                  ListItem(
                    title: Text('${item['from']} → ${item['to']}'),
                    subtitle: Text('${item['at']}\n${item['reason']}'),
                  ),
              ],
            ),
            generateSection(
              title: l.freev6TestHistory,
              items: [
                if (samples.isEmpty) ListItem(title: Text(l.freev6NoRecords)),
                for (final item in samples.reversed.take(100))
                  ListItem(
                    title: Text('${item['node']}'),
                    subtitle: Text('${item['at']}'),
                    trailing: Text(
                      item['failed'] == true
                          ? l.freev6Failed
                          : item['kind'] == 'delay'
                          ? '${item['delay']} ms'
                          : '${((item['rate'] as num? ?? 0) / 1000000).toStringAsFixed(2)} MB/s · ${item['connections'] ?? 1}',
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
