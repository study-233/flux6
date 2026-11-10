import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/sidebar.dart' as sidebar;

import '../components/app_glyphs.dart';

import '../app/client_model.dart';
import '../components/proxy_card.dart';

class Panel extends StatelessWidget {
  const Panel({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant
              .withValues(alpha: .55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String content,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

class NodesPage extends StatefulWidget {
  const NodesPage({super.key, required this.model});
  final ClientModel model;
  @override
  State<NodesPage> createState() => _NodesPageState();
}

enum _NodeOrder { name, delay }

class _NodesPageState extends State<NodesPage> {
  String query = '';
  _NodeOrder order = _NodeOrder.delay;
  final search = TextEditingController();
  final list = ScrollController();
  int columns = 1;
  double rowStride = 152;

  @override
  void dispose() {
    search.dispose();
    list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final colors = Theme.of(context).colorScheme;
    final allNodes = m.nodes.toList()
      ..sort((a, b) {
        if (order == _NodeOrder.name) return a.compareTo(b);
        int delay(String node) {
          final value = m.latency(node);
          return value == null || value < 0 ? 999999 : value;
        }

        final compared = delay(a).compareTo(delay(b));
        return compared == 0 ? a.compareTo(b) : compared;
      });
    final nodes = allNodes
        .where((n) => n.toLowerCase().contains(query.toLowerCase()))
        .toList();
    final chainAvailable =
        m.proxyTab == 'chain' || (m.chain['count'] as num? ?? 0) > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chainAvailable) ...[
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final item in [('access', '接入点'), ('chain', '链式代理')])
                  ChoiceChip(
                    label: Text(item.$2),
                    selected: m.proxyTab == item.$1,
                    onSelected: (_) => m.act('node.group', {'tab': item.$1}),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Semantics(
            label: '搜索节点',
            textField: true,
            child: TextField(
              controller: search,
              decoration: InputDecoration(
                hintText: '搜索节点',
                filled: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除节点搜索',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          search.clear();
                          setState(() => query = '');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LayoutBuilder(
              builder: (context, room) {
                final summary = Text(
                  '${m.proxyTab == 'chain' ? '链式代理' : '当前会话'} · ${m.nodes.length} 个节点',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                );
                final actions = Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PopupMenuButton<_NodeOrder>(
                      tooltip: '节点排序',
                      initialValue: order,
                      onSelected: (value) => setState(() => order = value),
                      itemBuilder: (_) => [
                        for (final value in _NodeOrder.values)
                          CheckedPopupMenuItem(
                            value: value,
                            checked: order == value,
                            child: Text(value == _NodeOrder.name ? '名称' : '延迟'),
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
                            Text(order == _NodeOrder.name ? '名称' : '延迟'),
                            const Icon(Icons.expand_more_rounded, size: 18),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '定位当前节点',
                      icon: const Icon(Icons.my_location_rounded, size: 18),
                      onPressed: m.currentNode == null
                          ? null
                          : () {
                              search.clear();
                              setState(() => query = '');
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted || !list.hasClients) return;
                                final index = allNodes.indexOf(
                                  m.currentNode ?? '',
                                );
                                if (index < 0) return;
                                list.jumpTo(
                                  ((index ~/ columns) * rowStride).clamp(
                                    0.0,
                                    list.position.maxScrollExtent,
                                  ),
                                );
                              });
                            },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.bolt_rounded, size: 17),
                      label: const Text('整组测延迟'),
                      onPressed: m.canMeasure && !m.pending('nodes.measure')
                          ? () => m.act('nodes.measure')
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
          if (!m.connected)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('连接后可以切换节点和测试延迟。'),
            ),
          Expanded(
            child: nodes.isEmpty
                ? Center(
                    child: Text(query.isEmpty ? '暂无节点，请先检查配置。' : '没有匹配的节点'),
                  )
                : LayoutBuilder(
                    builder: (context, room) {
                      final scale = MediaQuery.textScalerOf(context)
                          .scale(1)
                          .clamp(1.0, 2.0);
                      columns = (room.maxWidth ~/ 235).clamp(1, 5);
                      rowStride = 142 * scale + 10;
                      return GridView.builder(
                        controller: list,
                        itemCount: nodes.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: 142 * scale,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemBuilder: (context, index) {
                          final node = nodes[index];
                          final latency = m.latency(node);
                          return HostProxyCard(
                            key: ValueKey('node:$node'),
                            name: node,
                            selected: m.preferredNode == node,
                            active: m.connected && m.currentNode == node,
                            status: m.connected && m.currentNode == node
                                ? '使用中'
                                : '可选',
                            delay: latency == null
                                ? '—'
                                : latency < 0
                                ? '超时'
                                : '$latency ms',
                            onSelect: m.connected && m.canSelectNode
                                ? () => m.selectNode(node)
                                : null,
                            showMeasure: true,
                            measuring: m.measuring(node),
                            onMeasure: m.canMeasure
                                ? () => m.measure(node)
                                : null,
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class ConfigurationPage extends StatefulWidget {
  const ConfigurationPage({super.key, required this.model});
  final ClientModel model;
  @override
  State<ConfigurationPage> createState() => _ConfigurationPageState();
}

class _ConfigurationPageState extends State<ConfigurationPage> {
  final url = TextEditingController(), portal = TextEditingController();
  String? chainError, cloudError;
  @override
  void dispose() {
    url.dispose();
    portal.dispose();
    super.dispose();
  }

  Future<void> importChain() async {
    final uri = Uri.tryParse(url.text.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => chainError = '请输入完整的 HTTP 或 HTTPS 订阅地址');
      return;
    }
    setState(() => chainError = null);
    final ok = await widget.model.act('chain.import', {'url': url.text.trim()});
    if (mounted && !ok)
      setState(() => chainError = widget.model.message ?? '导入失败，请重试');
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Panel(
          title: '绕过校园网 / 白名单',
          children: [
            Text(
              ((m.settings['campusCidrs'] as List?) ?? ['edu.cn']).join('、'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => editBypass(context, m),
                child: const Text('编辑白名单'),
              ),
            ),
          ],
        ),
        Panel(
          title: '链式代理',
          children: [
            Text('已导入 ${m.chain['count'] ?? 0} 个节点'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用链式代理'),
              value: m.setting('chainEnabled'),
              onChanged: (v) => m.act('settings.save', {'chainEnabled': v}),
            ),
            TextField(
              controller: url,
              decoration: InputDecoration(
                labelText: '订阅地址',
                hintText: 'https://',
                errorText: chainError,
              ),
              onSubmitted: (_) => importChain(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: m.pending('chain.import') ? null : importChain,
                  child: Text(m.pending('chain.import') ? '导入中…' : '导入订阅'),
                ),
                OutlinedButton(
                  onPressed: () => m.act('chain.file'),
                  child: const Text('从文件导入'),
                ),
                TextButton(
                  onPressed: () async {
                    if (await confirm(context, '清除链式代理？', '清除后将不再使用已导入的链式节点。'))
                      await m.act('chain.clear');
                  },
                  child: const Text('清除'),
                ),
              ],
            ),
          ],
        ),
        Panel(
          title: '备用配置',
          children: [
            Text(
              m.cloud['locked'] == true
                  ? '维护者当前未开放备用配置'
                  : '已导入 ${m.cloud['count'] ?? 0} 个节点',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用备用配置'),
              value: m.setting('cloudEnabled'),
              onChanged: m.cloud['locked'] == true
                  ? null
                  : (v) => m.act('settings.save', {'cloudEnabled': v}),
            ),
            TextField(
              controller: portal,
              decoration: InputDecoration(
                labelText: '校园门户地址',
                errorText: cloudError,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed:
                      m.cloud['locked'] == true || m.pending('cloud.import')
                      ? null
                      : () async {
                          if (portal.text.trim().isEmpty) {
                            setState(() => cloudError = '请输入门户地址');
                            return;
                          }
                          setState(() => cloudError = null);
                          final ok = await m.act('cloud.import', {
                            'portalHost': portal.text.trim(),
                          });
                          if (mounted && !ok)
                            setState(() => cloudError = m.message ?? '导入失败');
                        },
                  child: const Text('获取配置'),
                ),
                TextButton(
                  onPressed: () async {
                    if (await confirm(context, '清除备用配置？', '清除后将恢复默认出口。'))
                      await m.act('cloud.clear');
                  },
                  child: const Text('清除'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> editBypass(BuildContext context, ClientModel m) async {
  final controller = TextEditingController(
    text: ((m.settings['campusCidrs'] as List?) ?? []).join('\n'),
  );
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('编辑白名单'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: '每行一个域名或 CIDR',
              errorText: error,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final entries = controller.text
                  .split(RegExp(r'[\n,，]'))
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              final ok = await m.act('settings.save', {'campusCidrs': entries});
              if (!context.mounted) return;
              if (ok)
                Navigator.pop(context);
              else
                setState(() => error = m.message ?? '保存失败');
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
}

class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.model});
  final ClientModel model;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => Clipboard.setData(
              ClipboardData(
                text: model.logs
                    .map(
                      (l) =>
                          '${l.time.toIso8601String()} [${l.level}] ${l.message}',
                    )
                    .join('\n'),
              ),
            ),
            icon: const Icon(Icons.copy),
            label: const Text('复制日志'),
          ),
          TextButton(
            onPressed: () => model.act('logs.clear'),
            child: const Text('清空日志'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (model.logs.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 64),
          child: Column(
            children: [
              Icon(
                Icons.history_rounded,
                size: 36,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              const Text('暂无日志'),
              const SizedBox(height: 6),
              Text(
                '连接状态与操作记录会显示在这里',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      for (final log in model.logs)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            log.level == '警告' ? Icons.error_outline : Icons.info_outline,
          ),
          title: SelectableText(log.message),
          subtitle: Text(
            '${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}:${log.time.second.toString().padLeft(2, '0')} · ${log.level}',
          ),
        ),
    ],
  );
}

Future<void> showNotices(BuildContext context, ClientModel m) async {
  await m.act('notice.read');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('公告'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: m.notices.isEmpty
                ? [const Text('暂无公告')]
                : [
                    for (final item in m.notices)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item['title'] ?? ''}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              '${item['body'] ?? item['content'] ?? ''}',
                            ),
                            if (item['link'] case final String link)
                              TextButton(
                                onPressed: () =>
                                    m.act('external.open', {'url': link}),
                                child: Text('${item['linkText'] ?? '查看详情'}'),
                              ),
                          ],
                        ),
                      ),
                  ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.model});
  final ClientModel model;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int page = 0;
  static const destinations = [
    sidebar.SidebarDestination(glyph: AppGlyphs.settings, label: '通用'),
    sidebar.SidebarDestination(glyph: AppGlyphs.dashboard, label: '外观'),
    sidebar.SidebarDestination(glyph: AppGlyphs.proxies, label: '接入'),
    sidebar.SidebarDestination(glyph: AppGlyphs.resources, label: '数据'),
    sidebar.SidebarDestination(glyph: AppGlyphs.logs, label: '关于'),
  ];
  ClientModel get model => widget.model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final m = model;
      Widget toggle(String key, String title, String detail) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(detail),
        value: m.setting(key),
        onChanged: m.pending('settings.save')
            ? null
            : (v) async {
                if (key == 'devMode' &&
                    v &&
                    !await confirm(
                      context,
                      '打开开发者模式？',
                      '开发者模式允许直连及跳过部分网络限制，请谨慎操作。',
                    ))
                  return;
                await m.act('settings.save', {key: v});
              },
      );
      Widget prefToggle(String key, String title, [bool defaultOn = false]) =>
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            value: m.preference(key, defaultOn ? '1' : '0') == '1',
            onChanged: (v) =>
                m.act('preferences.set', {'key': key, 'value': v ? '1' : '0'}),
          );
      Widget choice(
        String key,
        String title,
        Map<String, String> options,
        String fallback,
      ) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DropdownButtonFormField<String>(
          initialValue: options.containsKey(m.preference(key))
              ? m.preference(key)
              : fallback,
          decoration: InputDecoration(labelText: title),
          items: [
            for (final entry in options.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (v) {
            if (v != null) m.act('preferences.set', {'key': key, 'value': v});
          },
        ),
      );
      return LayoutBuilder(
        builder: (context, room) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sidebar.NavigationSidebar(
              destinations: destinations,
              selectedIndex: page,
              expanded: room.maxWidth >= 750,
              windowControls: const Size(78, 0),
              onSelected: (value) => setState(() => page = value),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            destinations[page].label,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭设置',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  if (m.message case final String message)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: page,
                      sizing: StackFit.expand,
                      children: [
                        for (final section in <Widget>[
                          Panel(
                            title: '通用',
                            children: [
                              toggle(
                                'autoStart',
                                '开机自启动',
                                '登录 Windows 时打开 FreeV6',
                              ),
                              toggle('silentStart', '静默启动', '启动后驻留托盘'),
                              toggle('autoRunProxy', '自动运行免流', '打开后自动尝试连接'),
                              toggle('hotkeyEnabled', 'F6 快捷键', '按 F6 显示主窗口'),
                              toggle(
                                'hotspotShare',
                                '共享移动热点',
                                '连接时尝试将已开启的热点切换到代理出口',
                              ),
                              toggle('devMode', '开发者模式', '开放直连模式与开发选项'),
                            ],
                          ),
                          Panel(
                            title: '外观',
                            children: [
                              choice('freev6-theme', '主题', {
                                'system': '跟随系统',
                                'light': '浅色',
                                'dark': '深色',
                              }, 'system'),
                              prefToggle('freev6-dynamic-color', '动态取色'),
                              prefToggle('freev6-pure-black', '纯黑背景'),
                              choice('freev6-bg-mode', '背景', {
                                'default': '默认',
                                'wallpaper': '壁纸',
                                'acrylic': '亚克力',
                                'mica': '云母',
                              }, 'default'),
                              prefToggle('freev6-webgl-glass', '玻璃效果', true),
                              prefToggle('reduce-motion', '减少动态效果'),
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: () => m.act('wallpaper.choose'),
                                    child: const Text('更换壁纸'),
                                  ),
                                  TextButton(
                                    onPressed: () => m.act('wallpaper.clear'),
                                    child: const Text('清除壁纸'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          Panel(
                            title: '核心与接入凭据',
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('运行核心'),
                                subtitle: Text(
                                  m.runtime['present'] == true ? '已安装' : '未安装',
                                ),
                                trailing: OutlinedButton(
                                  onPressed: m.pending('core.download')
                                      ? null
                                      : () => m.act('core.download'),
                                  child: const Text('下载核心'),
                                ),
                              ),
                              if (m.coreDownload['state'] == 'downloading')
                                const LinearProgressIndicator(),
                              if (m.coreDownload['error'] != null)
                                Text('${m.coreDownload['error']}'),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('WARP 接入凭据'),
                                subtitle: Text(
                                  m.runtime['warpRegistered'] == true
                                      ? '已注册'
                                      : '未注册',
                                ),
                                trailing: OutlinedButton(
                                  onPressed: m.pending('warp.register')
                                      ? null
                                      : () => m.act('warp.register'),
                                  child: Text(
                                    m.runtime['warpRegistered'] == true
                                        ? '重新注册'
                                        : '注册',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Panel(
                            title: '数据与维护',
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: () =>
                                        m.act('preferences.import'),
                                    child: const Text('导入旧版界面备份'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () =>
                                        m.act('preferences.export'),
                                    child: const Text('导出界面备份'),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      if (await confirm(
                                        context,
                                        '重置设置？',
                                        '将恢复默认设置，撤销自启动，并清除链式和备用配置。接入凭据与界面历史会保留。',
                                      ))
                                        await m.act('settings.reset');
                                    },
                                    child: const Text('重置设置'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          Panel(
                            title: '关于 FreeV6',
                            children: [
                              Text(
                                m.preview
                                    ? 'Windows 界面预览'
                                    : 'Windows 客户端 ${m.runtime['appVersion'] ?? ''}',
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: m.pending('update.check')
                                        ? null
                                        : () => m.act('update.check'),
                                    child: const Text('检查更新'),
                                  ),
                                  if (m.update['available'] == true)
                                    FilledButton(
                                      onPressed: m.pending('update.install')
                                          ? null
                                          : () async {
                                              if (await confirm(
                                                context,
                                                '安装更新',
                                                '下载并校验后，会停止连接并打开安装器。',
                                              ))
                                                await m.act('update.install');
                                            },
                                      child: Text('更新至 ${m.update['version']}'),
                                    ),
                                  if (m.update['available'] == true)
                                    TextButton(
                                      onPressed: () => m.act('update.skip'),
                                      child: const Text('忽略此版本'),
                                    ),
                                  TextButton(
                                    onPressed: () => m.act('external.open', {
                                      'url': 'https://github.com/study-233/free-v6',
                                    }),
                                    child: const Text('GitHub'),
                                  ),
                                  TextButton(
                                    onPressed: () => m.act('external.open', {
                                      'url': 'https://github.com/study-233/free-v6/issues',
                                    }),
                                    child: const Text('反馈'),
                                  ),
                                  TextButton(
                                    onPressed: () => showLicensePage(
                                      context: context,
                                      applicationName: 'FreeV6',
                                    ),
                                    child: const Text('开源许可证'),
                                  ),
                                ],
                              ),
                              if (m.pending('update.install')) ...[
                                const LinearProgressIndicator(),
                                Text(
                                  '已下载 ${m.update['done'] ?? 0} / ${m.update['total'] ?? '未知'} 字节',
                                ),
                              ],
                              if (m.update['notes'] case final String notes)
                                SelectableText(notes),
                              if (m.update['available'] == false)
                                Text(
                                  m.preference('freev6-skip-version') ==
                                          m.update['version']
                                      ? '已忽略此版本，可再次检查更新'
                                      : '当前已是最新版本',
                                ),
                              if (!m.preview)
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('返回应用'),
                                ),
                            ],
                          ),
                        ])
                          ListView(
                            padding: const EdgeInsets.all(20),
                            children: [section],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
