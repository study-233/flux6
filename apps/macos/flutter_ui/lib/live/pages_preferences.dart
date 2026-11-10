part of 'pages.dart';

class LiveSettingsPage extends StatefulWidget {
  const LiveSettingsPage({super.key, required this.model});
  final LiveModel model;
  @override
  State<LiveSettingsPage> createState() => _LiveSettingsState();
}

class _LiveSettingsState extends State<LiveSettingsPage> {
  static const tabs = [
    prism.SidebarDestination(glyph: AppGlyphs.dashboard, label: '通用'),
    prism.SidebarDestination(glyph: AppGlyphs.profiles, label: '代理规则'),
    prism.SidebarDestination(glyph: AppGlyphs.proxies, label: 'WARP 账户'),
    prism.SidebarDestination(glyph: AppGlyphs.resources, label: '核心与数据'),
    prism.SidebarDestination(glyph: AppGlyphs.dns, label: '网络服务'),
  ];
  bool? expanded;
  int page = 0;
  LiveModel get model => widget.model;
  StreamSubscription<String>? menu;
  @override
  void initState() {
    super.initState();
    menu = model.uiActions.listen((action) {
      if (action == 'save') unawaited(model.finishDrafts(true));
      if (action == 'import' && page != 1) {
        setState(() => page = 1);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) model.deliverUiAction(action);
        });
      }
    });
  }

  @override
  void dispose() {
    menu?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      if (_settings(model)['accepted'] != true)
        return LivePreparationPage(model: model);
      return LayoutBuilder(
        builder: (context, box) {
          final wide = expanded ?? box.maxWidth >= 750;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              prism.NavigationSidebar(
                destinations: tabs,
                selectedIndex: page,
                expanded: wide,
                windowControls: const Size(78, 32),
                onSelected: (v) => setState(() => page = v),
                onToggle: () => setState(() => expanded = !wide),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                      child: Text(
                        tabs[page].label,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: page,
                        sizing: StackFit.expand,
                        children: [
                          _general(context),
                          LiveConfigurationPage(
                            model: model,
                            window: 'settings',
                            active: page == 1,
                          ),
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [_account(context, model)],
                          ),
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [_resources(context, model)],
                          ),
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [_service(context, model)],
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
    },
  );

  Widget _general(BuildContext context) {
    final preferences = _section(model, 'preferences'),
        update = _section(model, 'update');
    Future<void> set(String field, dynamic value) async {
      await model.command('preferences.set', {'field': field, 'value': value});
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      children: [
        _Section('外观', [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('跟随系统')),
                ButtonSegment(value: 'light', label: Text('浅色')),
                ButtonSegment(value: 'dark', label: Text('深色')),
              ],
              selected: {preferences['appearance'] as String? ?? 'system'},
              onSelectionChanged: (v) =>
                  _run(context, () => set('appearance', v.first)),
            ),
          ),
          _toggle(context, '减少动态效果', 'reduceMotion', preferences, set),
        ]),
        _Section('启动与菜单栏', [
          _toggle(context, '在菜单栏显示 FreeV6', 'showMenuBar', preferences, set),
          _toggle(context, '启动时收起主窗口', 'hideOnStart', preferences, set),
          if (preferences['showMenuBar'] == false &&
              preferences['hideOnStart'] == true)
            const _Hint('菜单栏入口已关闭，启动时会显示主窗口。'),
          _toggle(context, '启动时自动连接', 'autoConnect', preferences, set),
          _toggle(context, '登录时打开 FreeV6', 'login', preferences, set),
          if ((preferences['loginStatus'] ?? '') != '')
            _Hint(preferences['loginStatus'] as String),
          if (preferences['needsLoginApproval'] == true)
            _Action('打开系统登录项设置', () => model.platform('openLoginSettings')),
        ]),
        _Section('应用更新', [
          _Hint(update['status']?.toString() ?? ''),
          _Action(
            '检查更新',
            update['available'] == true
                ? () => model.platform('checkUpdates')
                : null,
            icon: Icons.system_update_alt,
          ),
        ]),
      ],
    );
  }

  Widget _toggle(
    BuildContext context,
    String title,
    String key,
    StateMap values,
    Future<void> Function(String, dynamic) set,
  ) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    value: values[key] == true,
    onChanged: (value) => _run(context, () => set(key, value)),
  );
}

Widget _account(BuildContext context, LiveModel model) {
  final state = _section(model, 'preparation'),
      locked = _settings(model)['busy'] == true || model.busy;
  final canModify = _canPrepare(model) && !locked;
  return _Section('WARP 账户', [
    _Hint(state['accountStatus']?.toString() ?? '正在载入账户状态…'),
    if (state['active'] == 'preparation.warpRegister')
      _preparationProgress(model, state),
    Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        _Action(
          '检查已保存账户',
          locked ? null : () => model.command('preparation.warpInspect'),
        ),
        _Action(
          state['hasAccount'] == true ? '重新注册…' : '注册账户',
          !canModify || state['pendingCredential'] == true
              ? null
              : () async {
                  final value = await _registerName(
                    context,
                    state['hasAccount'] == true,
                  );
                  if (value != null)
                    await model.command('preparation.warpRegister', {
                      'device': value,
                    });
                },
        ),
        if (state['hasAccount'] == true)
          _Action(
            '删除账户…',
            !canModify
                ? null
                : () async {
                    if (await _confirm(
                      context,
                      '删除 WARP 账户？',
                      '此操作删除本机保存的凭据。下次连接或检查 WARP 配置时会自动注册。',
                      '删除',
                    )) {
                      await model.command('preparation.warpDelete');
                    }
                  },
          ),
        if (state['pendingCredential'] == true) ...[
          _Action(
            '重试保存凭据',
            !canModify ? null : () => model.command('preparation.warpRetry'),
          ),
          _Action(
            '放弃本次注册…',
            locked
                ? null
                : () async {
                    if (await _confirm(
                      context,
                      '放弃本次凭据？',
                      '尚未保存的注册结果将被清除。',
                      '放弃',
                    ))
                      await model.command('preparation.warpDiscard');
                  },
          ),
        ],
      ],
    ),
  ]);
}

Widget _resources(BuildContext context, LiveModel model) {
  final p = _section(model, 'preparation'),
      busy = _settings(model)['busy'] == true || model.busy;
  return _Section('核心与规则数据', [
    if (['preparation.core', 'preparation.geodata'].contains(p['active']))
      _preparationProgress(model, p),
    ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('网络核心'),
      subtitle: Text(p['core'] as String? ?? '尚未检查'),
      trailing: _Action(
        '准备核心',
        busy || !_canPrepare(model) || p['coreReady'] == true
            ? null
            : () => model.command('preparation.core'),
      ),
    ),
    ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('规则数据'),
      subtitle: Text(p['geodata'] as String? ?? '尚未检查'),
      trailing: _Action(
        '准备规则数据',
        busy || !_canPrepare(model) || p['geodataReady'] == true
            ? null
            : () => model.command('preparation.geodata'),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: _Action(
        '重新检查本机资源',
        busy ? null : () => model.command('preparation.inspectResources'),
      ),
    ),
  ]);
}

Widget _service(BuildContext context, LiveModel model) {
  final service = model.state['service']?.toString() ?? 'checking';
  final text = switch (service) {
    'ready' => '服务已就绪',
    'missing' => '需要安装网络服务',
    'needsRepair' => '服务需要检查',
    'managing' => '正在维护服务',
    _ => '正在确认服务状态',
  };
  final safe =
      model.capability('prepareService') &&
      !model.connected &&
      !model.busy &&
      model.phase != 'recovering' &&
      model.phase != 'occupied';
  return _Section('网络服务', [
    ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(text),
      subtitle: Text(
        service == 'ready' ? model.phaseLabel : '网络服务用于管理连接；安装或修复时需要系统授权。',
      ),
    ),
    Wrap(
      spacing: 4,
      children: [
        _Action('刷新状态', () => model.command('refresh')),
        if (model.phase == 'recovering')
          _Action('重试恢复网络', () => model.command('retryRecovery')),
        _Action(
          service == 'missing' ? '安装网络服务…' : '修复网络服务…',
          safe
              ? () => model.command('prepareService', {'action': 'install'})
              : null,
        ),
        _Action(
          '恢复未完成的安装…',
          safe
              ? () => model.command('prepareService', {'action': 'recover'})
              : null,
        ),
        if (service == 'ready')
          _Action(
            '卸载服务…',
            safe
                ? () async {
                    if (await _confirm(context, '卸载网络服务？', '之后可以重新安装服务。', '卸载'))
                      await model.command('prepareService', {
                        'action': 'uninstall',
                      });
                  }
                : null,
          ),
      ],
    ),
  ]);
}

class LivePreparationPage extends StatefulWidget {
  const LivePreparationPage({
    super.key,
    required this.model,
    this.maintenance = false,
  });
  final LiveModel model;
  final bool maintenance;
  @override
  State<LivePreparationPage> createState() => _PreparationState();
}

class _PreparationState extends State<LivePreparationPage> {
  bool privacy = false, accepting = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final s = _settings(widget.model),
          onboarding = _section(widget.model, 'onboarding');
      if (s.isEmpty) return const Center(child: CircularProgressIndicator());
      if (s['accepted'] == true) {
        if (!widget.maintenance) return _SetupWizard(model: widget.model);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
                const _Hint('检查连接资源，或修复网络服务。'),
                _service(context, widget.model),
                _resources(context, widget.model),
                _account(context, widget.model),
                _configurationCheck(widget.model),
              ],
            ),
          ),
        );
      }
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '欢迎使用 FreeV6',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const _Hint('首次使用前，请阅读用户协议与隐私政策。'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('用户协议')),
                      ButtonSegment(value: true, label: Text('隐私政策')),
                    ],
                    selected: {privacy},
                    onSelectionChanged: (v) =>
                        setState(() => privacy = v.first),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _NoticeDocument(
                    key: ValueKey(privacy),
                    source: onboarding['approvalAvailable'] == true
                        ? onboarding[privacy ? 'privacy' : 'agreement']
                              as String
                        : '无法读取随应用提供的文档，请重新安装完整应用。',
                  ),
                ),
                const Divider(),
                Row(
                  children: [
                    _Action('退出', () => widget.model.platform('quit')),
                    const Spacer(),
                    FilledButton(
                      onPressed:
                          accepting || onboarding['approvalAvailable'] != true
                          ? null
                          : () async {
                              setState(() => accepting = true);
                              await _run(
                                context,
                                () =>
                                    widget.model.command('preparation.accept'),
                              );
                              if (mounted) setState(() => accepting = false);
                            },
                      child: Text(accepting ? '正在载入…' : '同意用户协议与隐私政策'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _NoticeDocument extends StatelessWidget {
  const _NoticeDocument({super.key, required this.source});
  final String source;
  @override
  Widget build(BuildContext context) {
    final blocks = source
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
        .replaceAll('</br>', '')
        .split(RegExp(r'\n\s*\n'));
    return ListView.builder(
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final text = blocks[index].trim();
        if (text.isEmpty) return const SizedBox.shrink();
        if (text == '---') return const Divider();
        final heading = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(text);
        if (heading != null)
          return Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                heading.group(2)!,
                style: heading.group(1) == '#'
                    ? Theme.of(context).textTheme.titleLarge
                    : Theme.of(context).textTheme.titleMedium,
              ),
            ),
          );
        final runs = text.split('**');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SelectableText.rich(
            TextSpan(
              children: [
                for (var i = 0; i < runs.length; i++)
                  TextSpan(
                    text: runs[i].replaceAll('`', ''),
                    style: i.isOdd
                        ? const TextStyle(fontWeight: FontWeight.w700)
                        : null,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Widget _configurationCheck(LiveModel model) {
  final message = model.state['configurationCheckMessage'] as String?;
  return _Section('连接配置检查', [
    _Hint(message ?? '保存代理规则并准备核心与规则数据后，即可检查配置。缺少 WARP 凭据时会自动注册。'),
    Align(
      alignment: Alignment.centerLeft,
      child: _Action(
        '检查连接配置',
        model.capability('checkConfiguration')
            ? () => model.command('checkConfiguration')
            : null,
        icon: Icons.fact_check_outlined,
      ),
    ),
  ]);
}

Widget _preparationProgress(LiveModel model, StateMap state) => Row(
  children: [
    const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    const SizedBox(width: 8),
    Expanded(child: Text(state['progress']?.toString() ?? '正在处理…')),
    if (state['canCancel'] == true)
      _Action('取消操作', () => model.command('preparation.cancel')),
  ],
);

Future<String?> _registerName(BuildContext context, bool replacing) {
  var device = 'freev6-macos';
  return showDialog<String>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, rebuild) => AlertDialog(
        title: Text(replacing ? '重新注册 WARP 账户？' : '注册 WARP 账户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Hint(
              replacing ? '新凭据成功保存后会替换旧凭据。' : '设备名称将随注册请求发送。正式账户凭据存入本机钥匙串。',
            ),
            TextFormField(
              initialValue: device,
              autofocus: true,
              onChanged: (v) => rebuild(() => device = v),
              decoration: const InputDecoration(labelText: '设备名称'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: device.trim().isEmpty
                ? null
                : () => Navigator.pop(dialog, device.trim()),
            child: Text(replacing ? '重新注册' : '注册'),
          ),
        ],
      ),
    ),
  );
}

bool _canPrepare(LiveModel model) =>
    model.phase == 'idle' ||
    model.phase == 'unknown' && model.state['service'] == 'missing';
