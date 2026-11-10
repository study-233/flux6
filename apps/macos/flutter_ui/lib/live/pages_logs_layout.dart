part of 'pages.dart';

String _logTime(Object? value) {
  final date = DateTime.fromMillisecondsSinceEpoch(
    (value as num?)?.toInt() ?? 0,
  ).toLocal();
  String n(int x) => x.toString().padLeft(2, '0');
  return '${n(date.month)}-${n(date.day)} ${n(date.hour)}:${n(date.minute)}:${n(date.second)}';
}

class LiveLogsPage extends StatefulWidget {
  const LiveLogsPage({super.key, required this.model, this.active = true});
  final LiveModel model;
  final bool active;
  @override
  State<LiveLogsPage> createState() => _LiveLogsState();
}

class _LiveLogsState extends State<LiveLogsPage> {
  late LiveLogPages pager;
  LiveModel get model => widget.model;
  void _sync() {
    pager.sync(_section(model, 'logs'), active: widget.active);
  }

  @override
  void initState() {
    super.initState();
    pager = LiveLogPages(model);
    model.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(LiveLogsPage old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    model.removeListener(_sync);
    pager.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final expected = pager.epoch;
    if (expected == null) return;
    final reply = await model.command('logs.export', {'epoch': expected});
    final result = readMap(reply['data']);
    if (!mounted || pager.epoch != expected || result['epoch'] != expected)
      return;
    await model.platform('exportText', {
      'name': 'Flux6-日志.txt',
      'text': result['text'],
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([model, pager]),
    builder: (context, _) {
      final log = _section(model, 'logs'), rows = pager.rows;
      final paused = log['paused'] == true;
      String line(StateMap row) =>
          '${_logTime(row['time'])}  [${row['level']}] [${row['source']}] ${row['message']}';
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PopupMenuButton<String>(
                  tooltip: '筛选日志级别',
                  onSelected: (v) => _run(
                    context,
                    () => model.command('logs.filter', {'level': v}),
                  ),
                  itemBuilder: (_) => [
                    for (final level in ['全部', '信息', '提醒', '错误'])
                      CheckedPopupMenuItem(
                        value: level,
                        checked: level == log['level'],
                        child: Text(level),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: Text(
                      log['level'] == '全部'
                          ? '全部级别 ▾'
                          : '${log['level'] ?? '全部级别'} ▾',
                    ),
                  ),
                ),
                _Action(
                  paused ? '继续显示' : '暂停显示',
                  () => model.command('logs.pause', {'paused': !paused}),
                  icon: paused ? Icons.play_arrow : Icons.pause,
                ),
                _Action(
                  '导出',
                  (log['count'] as int? ?? 0) == 0 ? null : _export,
                  icon: Icons.ios_share,
                ),
                _Action(
                  '清空…',
                  log['canClear'] != true
                      ? null
                      : () async {
                          if (await _confirm(
                            context,
                            '清空全部本机日志？',
                            '将清空所有级别和暂停显示的记录。之后到达的事件会继续记录。',
                            '清空全部',
                          )) {
                            await model.command('logs.clear');
                          }
                        },
                ),
                Text(
                  '${log['count'] ?? 0} 条',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            if (log['storageUnavailable'] == true)
              const _Hint('无法保存本机日志。仍可导出本次运行的事件。'),
            if (log['clearError'] is String && log['clearError'] != '')
              _Hint(log['clearError'] as String),
            if (paused) const _Hint('显示已暂停，后台继续记录事件。'),
            if (pager.error != null)
              Row(
                children: [
                  Expanded(child: _Hint(pager.error!)),
                  TextButton(onPressed: pager.retry, child: const Text('重新读取')),
                ],
              ),
            const Divider(height: 12),
            Expanded(
              child: !pager.initialized && pager.loading
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                  ? const Center(child: Text('当前级别暂无事件'))
                  : ListView.separated(
                      itemCount: rows.length + (pager.hasOlder ? 1 : 0),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == rows.length)
                          return Align(
                            child: TextButton(
                              onPressed: pager.loading
                                  ? null
                                  : () => pager.older(),
                              child: const Text('加载更早的记录'),
                            ),
                          );
                        final r = rows[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                          ),
                          leading: Icon(switch (r['level']) {
                            '错误' => Icons.error_outline,
                            '提醒' => Icons.warning_amber_rounded,
                            _ => Icons.info_outline,
                          }, size: 18),
                          title: SelectableText(r['message']?.toString() ?? ''),
                          subtitle: Text(
                            '${_logTime(r['time'])}   ·   ${r['source']}   ·   ${r['level']}',
                          ),
                          trailing: IconButton(
                            tooltip: '复制这条日志',
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            onPressed: () =>
                                Clipboard.setData(ClipboardData(text: line(r))),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}

class LiveNoticesPage extends StatefulWidget {
  const LiveNoticesPage({super.key, required this.model});
  final LiveModel model;
  @override
  State<LiveNoticesPage> createState() => _LiveNoticesState();
}

class _LiveNoticesState extends State<LiveNoticesPage> {
  String? selected;
  bool initial = true;
  void open(String id, bool read) {
    selected = id;
    if (!read)
      unawaited(
        _run(context, () => widget.model.command('notices.read', {'id': id})),
      );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final notice = _section(widget.model, 'notices'),
          items = readRecords(notice['items']);
      if (initial && items.isNotEmpty) {
        initial = false;
        final first =
            items.where((v) => v['read'] != true).firstOrNull ?? items.first;
        selected = first['id'] as String;
        if (first['read'] != true)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) open(first['id'] as String, false);
          });
      }
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('维护者公告', style: Theme.of(context).textTheme.titleLarge),
              _Action(
                '刷新',
                () => widget.model.command('notices.refresh'),
                icon: Icons.refresh,
              ),
              _Action(
                '全部标为已读',
                notice['unread'] == 0
                    ? null
                    : () => widget.model.command('notices.read', {'all': true}),
              ),
            ],
          ),
          if (notice['source'] == 'cache') const _Hint('显示缓存公告'),
          if (notice['error'] is String && notice['error'] != '')
            _Hint(notice['error'] as String),
          if (items.isEmpty)
            const Padding(padding: EdgeInsets.all(22), child: Text('暂无公告')),
          for (final item in items)
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    title: Text(item['title'] as String),
                    subtitle: Text(
                      (item['published'] as String).split('T').first,
                    ),
                    trailing: Icon(
                      item['id'] == selected
                          ? Icons.expand_less
                          : Icons.expand_more,
                    ),
                    leading: item['read'] == false
                        ? const Icon(Icons.mark_email_unread_outlined)
                        : null,
                    onTap: () => setState(() {
                      if (selected == item['id'])
                        selected = null;
                      else
                        open(item['id'] as String, item['read'] == true);
                    }),
                  ),
                  if (item['id'] == selected)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(item['body']?.toString() ?? ''),
                          if (item['link'] != '')
                            _Action(
                              '查看详情',
                              () => widget.model.platform('openURL', {
                                'url': item['link'],
                              }),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

const _tileNames = {
  'connection': '连接控制',
  'mode': '工作模式',
  'node': '接入节点',
  'usage': '用量统计',
  'speed': '实时速度',
};

class LiveLayoutPage extends StatefulWidget {
  const LiveLayoutPage({super.key, required this.model});
  final LiveModel model;
  @override
  State<LiveLayoutPage> createState() => _LiveLayoutState();
}

class _LiveLayoutState extends State<LiveLayoutPage> {
  bool ready = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    try {
      await widget.model.command('layout.edit', {'op': 'begin'});
      if (mounted) setState(() => ready = true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> edit(String op, [StateMap fields = const {}]) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.model.command('layout.edit', {'op': op, ...fields});
      if (mounted &&
          ['save', 'discard'].contains(op) &&
          Navigator.canPop(context))
        Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final tiles = readRecords(_settings(widget.model)['layoutEditor']),
          selected = tiles.map((t) => t['kind']).toList();
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('编辑仪表盘', style: Theme.of(context).textTheme.titleLarge),
                PopupMenuButton<String>(
                  tooltip: '添加小组件',
                  enabled: ready && !busy,
                  itemBuilder: (_) => _tileNames.entries
                      .map(
                        (e) => PopupMenuItem(
                          value: e.key,
                          enabled: !selected.contains(e.key),
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onSelected: (v) => edit('add', {'kind': v}),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('添加小组件 ▾'),
                  ),
                ),
                _Action('恢复默认', ready && !busy ? () => edit('reset') : null),
              ],
            ),
            if (error != null) _Hint(error!),
            Expanded(
              child: tiles.isEmpty
                  ? const Center(child: Text('尚未添加小组件'))
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: tiles.length,
                      onReorderItem: (from, to) {
                        final next = List.of(selected)..removeAt(from);
                        edit('move', {
                          'kind': selected[from],
                          'before': to < next.length ? next[to] : null,
                        });
                      },
                      itemBuilder: (context, i) {
                        final tile = tiles[i],
                            kind = tile['kind'] as String,
                            wide = tile['size'] == 'wide';
                        return ListTile(
                          key: ValueKey(kind),
                          leading: ReorderableDragStartListener(
                            index: i,
                            enabled: !busy,
                            child: const Icon(Icons.drag_handle),
                          ),
                          title: Text(_tileNames[kind] ?? kind),
                          subtitle: Text(wide ? '宽幅' : '紧凑'),
                          trailing: PopupMenuButton<String>(
                            tooltip: '调整${_tileNames[kind]}',
                            enabled: ready && !busy,
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'up',
                                enabled: i > 0,
                                child: const Text('前移'),
                              ),
                              PopupMenuItem(
                                value: 'down',
                                enabled: i + 1 < tiles.length,
                                child: const Text('后移'),
                              ),
                              PopupMenuItem(
                                value: 'resize',
                                child: Text(wide ? '改为紧凑' : '改为宽幅'),
                              ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('移除'),
                              ),
                            ],
                            onSelected: (op) {
                              if (op == 'up') {
                                edit('move', {
                                  'kind': kind,
                                  'before': selected[i - 1],
                                });
                              } else if (op == 'down') {
                                edit('move', {
                                  'kind': kind,
                                  'before': i + 2 < selected.length
                                      ? selected[i + 2]
                                      : null,
                                });
                              } else {
                                edit(op, {
                                  'kind': kind,
                                  'size': wide ? 'compact' : 'wide',
                                });
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: !ready || busy ? null : () => edit('discard'),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: !ready || busy ? null : () => edit('save'),
                  child: const Text('完成'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
