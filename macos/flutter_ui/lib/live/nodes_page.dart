import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/press_surface.dart';
import 'live_model.dart';
import '../components/proxy_card.dart';

enum _NodeOrder {
  name('名称', '名称（A → Z）'),
  download('下载速度', '下载速度（高 → 低）'),
  delay('延迟', '延迟（低 → 高）');

  const _NodeOrder(this.label, this.menuLabel);
  final String label, menuLabel;
}

int _compareNodeNames(String a, String b) {
  final parts = RegExp(r'\d+|\D+');
  final left = parts.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = parts.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = BigInt.tryParse(left[i]), y = BigInt.tryParse(right[i]);
    final order = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  final count = left.length.compareTo(right.length);
  return count != 0 ? count : a.compareTo(b);
}

Future<void> openLiveNodePicker(BuildContext context, LiveModel model) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 510, maxHeight: 510),
          child: LiveNodesPage(model: model, picker: true),
        ),
      ),
    );

class LiveNodesPage extends StatefulWidget {
  const LiveNodesPage({
    super.key,
    required this.model,
    this.picker = false,
    this.active = true,
  });
  final LiveModel model;
  final bool picker, active;
  @override
  State<LiveNodesPage> createState() => _LiveNodesPageState();
}

class _LiveNodesPageState extends State<LiveNodesPage> {
  String group = 'access', query = '';
  _NodeOrder order = _NodeOrder.name;
  List<String?> previousOptions = [];
  int highlighted = 0;
  final search = TextEditingController();
  final focus = FocusNode(debugLabel: 'FreeV6 node search'),
      list = ScrollController();
  StreamSubscription<String>? events;
  static const extent = 60.0;
  int columns = 1;
  double rowStride = extent;
  LiveModel get model => widget.model;
  @override
  void initState() {
    super.initState();
    group = model.group;
    focus.addListener(_focusChanged);
    events = model.uiActions.listen((action) {
      if (action == 'find' &&
          widget.active &&
          !widget.picker &&
          focus.canRequestFocus &&
          ModalRoute.of(context)?.isCurrent == true)
        focus.requestFocus();
    });
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    focus.removeListener(_focusChanged);
    events?.cancel();
    focus.dispose();
    list.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> choose(String? name) async {
    if (await model.chooseNode(group, name) && mounted && widget.picker)
      Navigator.pop(context);
  }

  List<String?> options(StateMap data) {
    final needle = query.trim().toLowerCase();
    final names = readStrings(
      data['members'],
    ).where((v) => v.toLowerCase().contains(needle)).toList();
    if (!widget.picker) {
      final results = readMap(
        readMap(readMap(model.state['download'])['results'])[group],
      );
      double? measurement(String name) {
        if (order == _NodeOrder.delay) {
          final delay = model.groupLatency(group, name);
          return delay != null && delay >= 0 ? delay.toDouble() : null;
        }
        final result = readMap(results[name]);
        final speed = (result['bytesPerSecond'] as num?)?.toDouble();
        return result['status'] == 'complete' &&
                speed != null &&
                speed.isFinite &&
                speed >= 0
            ? speed
            : null;
      }

      names.sort((a, b) {
        if (order != _NodeOrder.name) {
          final x = measurement(a), y = measurement(b);
          if (x == null && y != null) return 1;
          if (y == null && x != null) return -1;
          if (x != null && y != null) {
            final measured = order == _NodeOrder.download
                ? y.compareTo(x)
                : x.compareTo(y);
            if (measured != 0) return measured;
          }
        }
        return _compareNodeNames(a, b);
      });
    }
    return [if (group == 'access' && '自动选择'.contains(needle)) null, ...names];
  }

  void point(int index, List<String?> items) {
    if (items.isEmpty) return;
    setState(() => highlighted = index.clamp(0, items.length - 1));
    if (list.hasClients) {
      final top = (highlighted ~/ columns) * rowStride;
      if (top < list.offset ||
          top + extent > list.offset + list.position.viewportDimension) {
        list.jumpTo(top.clamp(0.0, list.position.maxScrollExtent));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final data = model.groupData(group);
      final members = options(data);
      // Live measurements can reorder cards while keyboard focus stays in the
      // search field. Keep the highlighted node's identity through that update.
      if (previousOptions.isNotEmpty && highlighted < previousOptions.length) {
        final position = members.indexOf(previousOptions[highlighted]);
        if (position >= 0) highlighted = position;
      }
      previousOptions = members;
      final selected = data['current'] ?? data['preferred'];
      final src = switch (data['source']) {
        'session' => '当前会话',
        'previousSession' => '上次会话',
        'configuration' => '本地配置',
        _ => '节点目录',
      };
      final colors = Theme.of(context).colorScheme;
      final download = readMap(model.state['download']);
      final results = readMap(readMap(download['results'])[group]);
      return Padding(
        padding: EdgeInsets.fromLTRB(18, widget.picker ? 14 : 6, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.picker)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择接入节点',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, semanticLabel: '关闭'),
                  ),
                ],
              ),
            if (!widget.picker && model.groups.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final item in model.groups)
                      ChoiceChip(
                        label: Text(item['id'] == 'access' ? '接入节点' : '链式代理'),
                        selected: group == item['id'],
                        onSelected: (_) => setState(() {
                          group = item['id'];
                          highlighted = 0;
                          previousOptions = [];
                          search.clear();
                          query = '';
                        }),
                      ),
                  ],
                ),
              ),
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: '搜索节点',
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      point(highlighted + 1, members),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      point(highlighted - 1, members),
                },
                child: TextField(
                  controller: search,
                  focusNode: focus,
                  autofocus: widget.picker,
                  onChanged: (value) => setState(() {
                    query = value;
                    highlighted = 0;
                    previousOptions = [];
                  }),
                  onSubmitted: (_) {
                    if (members.isNotEmpty && model.canSelectNode)
                      choose(members[highlighted.clamp(0, members.length - 1)]);
                  },
                  decoration: InputDecoration(
                    labelText: '搜索节点',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            icon: const Icon(
                              Icons.close,
                              semanticLabel: '清除搜索',
                            ),
                            onPressed: () {
                              search.clear();
                              setState(() {
                                query = '';
                                highlighted = 0;
                                previousOptions = [];
                              });
                            },
                          ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LayoutBuilder(
                builder: (context, room) {
                  final summary = Text(
                    '$src · ${readStrings(data['members']).length} 个节点',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  );
                  if (widget.picker) return summary;
                  final testing = download['active'] == true;
                  final cancelling = download['cancelling'] == true;
                  final actions = Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PopupMenuButton<_NodeOrder>(
                        tooltip: '节点排序',
                        initialValue: order,
                        onSelected: (value) => setState(() {
                          order = value;
                          highlighted = 0;
                          previousOptions = [];
                          if (list.hasClients) list.jumpTo(0);
                        }),
                        itemBuilder: (_) => [
                          for (final value in _NodeOrder.values)
                            CheckedPopupMenuItem(
                              value: value,
                              checked: order == value,
                              child: Text(value.menuLabel),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.sort_rounded, size: 18),
                              const SizedBox(width: 6),
                              Text(order.label),
                              const Icon(Icons.expand_more_rounded, size: 18),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '定位当前或预选节点',
                        icon: const Icon(Icons.my_location_rounded, size: 18),
                        onPressed: selected == null
                            ? null
                            : () {
                                setState(() {
                                  query = '';
                                  search.clear();
                                  previousOptions = [];
                                });
                                final items = options(data);
                                point(items.indexOf(selected), items);
                              },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.bolt_rounded, size: 17),
                        label: Text(query.isEmpty ? '整组测延迟' : '测量结果延迟'),
                        onPressed:
                            model.canMeasure &&
                                members.whereType<String>().isNotEmpty
                            ? () => model.measureGroup(
                                group,
                                members.whereType<String>().toList(),
                              )
                            : null,
                      ),
                      TextButton.icon(
                        icon: Icon(
                          testing
                              ? Icons.stop_circle_outlined
                              : Icons.download_rounded,
                          size: 17,
                        ),
                        label: Text(
                          testing
                              ? cancelling
                                    ? '正在停止…'
                                    : '停止测速 ${download['completed'] ?? 0}/${download['total'] ?? 1}'
                              : '整组测速',
                        ),
                        onPressed: testing
                            ? cancelling
                                  ? null
                                  : () => model.perform('download.cancel')
                            : model.capability('download') &&
                                  readStrings(data['members']).isNotEmpty
                            ? () => model.perform('download.start', {
                                'group': group,
                                'nodes': readStrings(data['members']),
                              })
                            : null,
                      ),
                    ],
                  );
                  if (room.maxWidth >=
                      720 * MediaQuery.textScalerOf(context).scale(1)) {
                    return Row(children: [summary, const Spacer(), actions]);
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [summary, const SizedBox(height: 4), actions],
                  );
                },
              ),
            ),
            Expanded(
              child: members.isEmpty
                  ? Center(
                      child: Text(query.isEmpty ? '暂无节点，请先检查配置。' : '没有匹配的节点'),
                    )
                  : !widget.picker
                  ? LayoutBuilder(
                      builder: (context, room) {
                        columns = (room.maxWidth ~/ 235).clamp(1, 5);
                        final height =
                            142 *
                            MediaQuery.textScalerOf(
                              context,
                            ).scale(1).clamp(1.0, 2.0);
                        rowStride = height + 10;
                        return GridView.builder(
                          controller: list,
                          itemCount: members.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: height,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                          itemBuilder: (context, i) {
                            final name = members[i];
                            final active =
                                name != null &&
                                model.connected &&
                                data['current'] == name;
                            final chosen = data['preferred'] == name;
                            final delay = name == null
                                ? null
                                : model.groupLatency(group, name);
                            final measuring =
                                name != null && model.measuringIn(group, name);
                            final result = readMap(results[name]);
                            final downloading =
                                download['active'] == true &&
                                download['group'] == group &&
                                download['node'] == name;
                            final rate = (result['bytesPerSecond'] as num?)
                                ?.toDouble();
                            final stamp = DateTime.tryParse(
                              result['time']?.toString() ?? '',
                            )?.toLocal();
                            final detail = stamp == null
                                ? ''
                                : '平均下载速度 · ${stamp.hour.toString().padLeft(2, '0')}:${stamp.minute.toString().padLeft(2, '0')} · ${((result['bytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MiB';
                            return HostProxyCard(
                              key: ValueKey('$group:${name ?? 'automatic'}'),
                              keyboardTarget:
                                  focus.hasFocus && highlighted == i,
                              name: name ?? '自动选择',
                              selected: chosen,
                              active: active,
                              status: name == null
                                  ? '按可用性选择'
                                  : active
                                  ? '使用中'
                                  : chosen
                                  ? '下次连接'
                                  : '可选',
                              onSelect: model.canSelectNode
                                  ? () => choose(name)
                                  : null,
                              showDownload: name != null,
                              downloading: downloading,
                              download: downloading
                                  ? '正在测速…'
                                  : rate != null
                                  ? '${(rate / 1000000).toStringAsFixed(2)} MB/s'
                                  : result['status'] == 'failed'
                                  ? '测速失败，点击重试'
                                  : result['status'] == 'cancelled'
                                  ? '已取消'
                                  : '下载未测速',
                              downloadDetail: detail,
                              onDownload: name == null
                                  ? null
                                  : downloading
                                  ? () => model.perform('download.cancel')
                                  : model.capability('download')
                                  ? () => model.perform('download.start', {
                                      'group': group,
                                      'node': name,
                                    })
                                  : null,
                              showMeasure: name != null,
                              measuring: measuring,
                              delay: delay == null
                                  ? '—'
                                  : delay < 0
                                  ? (delay == -1 ? '超时' : '不可用')
                                  : '$delay ms',
                              onMeasure:
                                  model.canMeasure && !measuring && name != null
                                  ? () => model.measureGroup(group, [name])
                                  : null,
                            );
                          },
                        );
                      },
                    )
                  : ListView.builder(
                      controller: list,
                      itemExtent: extent,
                      itemCount: members.length,
                      itemBuilder: (context, i) {
                        final name = members[i];
                        final active =
                            name != null &&
                            model.connected &&
                            data['current'] == name;
                        final preferred = data['preferred'] == name;
                        final status = name == null
                            ? '自动选择可用节点'
                            : active
                            ? '使用中'
                            : preferred
                            ? '下次连接'
                            : '可选';
                        final selected = preferred || active;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: ColoredBox(
                            color: selected
                                ? colors.primaryContainer.withValues(alpha: .45)
                                : widget.picker && i == highlighted
                                ? colors.surfaceContainer
                                : Colors.transparent,
                            child: Row(
                              children: [
                                Expanded(
                                  child: PressSurface(
                                    fill: Colors.transparent,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    onPressed: model.canSelectNode
                                        ? () => choose(name)
                                        : null,
                                    child: Row(
                                      children: [
                                        Icon(
                                          selected
                                              ? Icons.check_circle_outline
                                              : Icons.language_rounded,
                                          size: 19,
                                          color: selected
                                              ? colors.primary
                                              : colors.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                name ?? '自动选择',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                status,
                                                style: TextStyle(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (widget.picker && model.message != null)
              Text(model.message!, style: TextStyle(color: colors.error)),
          ],
        ),
      );
    },
  );
}
