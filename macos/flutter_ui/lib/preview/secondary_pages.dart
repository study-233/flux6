import 'package:flutter/material.dart';

import 'fixture_model.dart';
import 'node_picker.dart';

class FixtureNodesPage extends StatefulWidget {
  const FixtureNodesPage({super.key, required this.model});
  final FixtureModel model;

  @override
  State<FixtureNodesPage> createState() => _FixtureNodesPageState();
}

class _FixtureNodesPageState extends State<FixtureNodesPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final matches = model.nodes
            .where((n) => n.contains(_search.text.trim()))
            .toList();
        return ListView(
          key: const PageStorageKey('fixture-nodes'),
          padding: _pagePadding,
          children: [
            Row(
              children: [
                Expanded(
                  child: NodeSearchField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (model.connected) ...[
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: matches.isEmpty || matches.every(model.measuring)
                        ? null
                        : () => Future.wait(matches.map(model.measure)),
                    icon: const Icon(Icons.speed_rounded, size: 18),
                    label: Text(_search.text.trim().isEmpty ? '测量全组' : '测量结果'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            _Panel(
              children: [
                _TitleRow(
                  icon: Icons.hub_outlined,
                  title: model.profileName,
                  end: Text('${matches.length} 个节点'),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(
                    model.connected
                        ? '当前使用 · ${model.displayNode}'
                        : '下次连接 · ${model.displayNode}',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_search.text.trim().isEmpty) ...[
                  FixtureNodeRow(model: model, node: null),
                  const SizedBox(height: 6),
                ],
                for (final node in matches) ...[
                  FixtureNodeRow(model: model, node: node),
                  const SizedBox(height: 6),
                ],
                if (matches.isEmpty)
                  _Empty(text: '没有匹配的节点', icon: Icons.search_off_rounded),
              ],
            ),
          ],
        );
      },
    );
  }
}

class FixtureProfilePage extends StatelessWidget {
  const FixtureProfilePage({super.key, required this.model});
  final FixtureModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        return ListView(
          padding: _pagePadding,
          children: [
            _Panel(
              children: [
                const _TitleRow(
                  icon: Icons.description_outlined,
                  title: '当前配置',
                ),
                Text(
                  model.profileName,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const _InfoRow(label: '配置来源', value: '本地演示配置'),
                _InfoRow(label: '工作模式', value: model.mode),
                _InfoRow(
                  label: model.connected ? '当前节点' : '下次连接',
                  value: model.displayNode,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: model.busy
                        ? null
                        : () => showFixtureNodePicker(context, model),
                    icon: const Icon(Icons.hub_outlined, size: 16),
                    label: const Text('选择接入节点'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class FixtureLogsPage extends StatefulWidget {
  const FixtureLogsPage({super.key, required this.model});
  final FixtureModel model;

  @override
  State<FixtureLogsPage> createState() => _FixtureLogsPageState();
}

class _FixtureLogsPageState extends State<FixtureLogsPage> {
  String? _level;
  List<PreviewLog>? _paused;

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空预览日志？'),
        content: const Text('将清空全部级别的预览记录，包括暂停显示的内容。之后的新事件会继续记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空全部'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      if (_paused != null) _paused = [];
    });
    widget.model.clearLogs();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final all = _paused ?? model.logs;
        final records = all
            .where((r) => _level == null || r.level == _level)
            .toList();
        return Padding(
          padding: _pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PopupMenuButton<String>(
                    tooltip: '日志级别',
                    initialValue: _level ?? '全部',
                    onSelected: (v) =>
                        setState(() => _level = v == '全部' ? null : v),
                    itemBuilder: (_) => ['全部', '信息', '警告']
                        .map((v) => PopupMenuItem(value: v, child: Text(v)))
                        .toList(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.filter_list_rounded, size: 17),
                          const SizedBox(width: 4),
                          Text(_level ?? '全部级别'),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 17,
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(
                      () => _paused = _paused == null ? model.logs : null,
                    ),
                    icon: Icon(
                      _paused == null
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    label: Text(_paused == null ? '暂停显示' : '继续显示'),
                  ),
                  TextButton.icon(
                    onPressed: model.logs.isEmpty && (_paused?.isEmpty ?? true)
                        ? null
                        : _clear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 17),
                    label: const Text('清空…'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: records.isEmpty
                    ? _Empty(
                        text: _level == null ? '暂无日志' : '当前级别暂无事件',
                        icon: Icons.notes_rounded,
                      )
                    : ListView.separated(
                        key: const PageStorageKey('fixture-logs'),
                        itemCount: records.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 5),
                        itemBuilder: (context, i) {
                          final item = records[i];
                          String two(int v) => v.toString().padLeft(2, '0');
                          final time =
                              '${two(item.time.hour)}:${two(item.time.minute)}:${two(item.time.second)}';
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    time,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    item.level,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: item.level == '警告'
                                          ? colors.error
                                          : colors.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: SelectableText(
                                      item.message,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                ],
                              ),
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
}

const _pagePadding = EdgeInsets.fromLTRB(16, 8, 24, 24);

class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.icon, required this.title, this.end});
  final IconData icon;
  final String title;
  final Widget? end;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          if (end != null)
            DefaultTextStyle(
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              child: end!,
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text, required this.icon});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 26,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(text),
          ],
        ),
      ),
    );
  }
}
