part of 'pages.dart';

class LiveConfigurationPage extends StatefulWidget {
  const LiveConfigurationPage({
    super.key,
    required this.model,
    this.window = 'main',
    this.active = true,
  });
  final LiveModel model;
  final String window;
  final bool active;
  @override
  State<LiveConfigurationPage> createState() => _LiveConfigurationState();
}

class _LiveConfigurationState extends State<LiveConfigurationPage> {
  final _text = {
    for (final key in ['campus', 'blacklist']) key: TextEditingController(),
  };
  final _focus = {
    for (final key in ['campus', 'blacklist']) key: FocusNode(),
  };
  final _anchors = {
    for (final key in ['campus', 'blacklist']) key: GlobalKey(),
  };
  final _pending = <String, dynamic>{};
  final _scroll = ScrollController();
  Future<void>? _savingChanges;
  String? _writeFailure, _shownIssue;
  StreamSubscription<String>? _menu;
  LiveModel get model => widget.model;
  StateMap get _rules => readMap(_section(model, 'rules')[widget.window]);

  @override
  void initState() {
    super.initState();
    model.addListener(_sync);
    _sync();
    model.draftHandlers['rules.${widget.window}'] = _finishInput;
    _menu = model.uiActions.listen((action) {
      if (widget.active &&
          action == 'import' &&
          mounted &&
          ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_file('chain'));
      }
    });
  }

  @override
  void dispose() {
    model.removeListener(_sync);
    model.draftHandlers.remove('rules.${widget.window}');
    _menu?.cancel();
    _scroll.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(LiveConfigurationPage previous) {
    super.didUpdateWidget(previous);
    if (widget.active && !previous.active) _sync();
  }

  void _sync() {
    final rules = _rules;
    for (final item in _text.entries) {
      final field = item.key, controller = item.value;
      final value = rules[field]?.toString() ?? '';
      if (_savingChanges == null &&
          !_pending.containsKey(field) &&
          controller.text != value) {
        controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    }
    final issue = readMap(rules['issue']);
    if (issue.isEmpty) {
      _shownIssue = null;
      return;
    }
    final signature = '${issue['field']}-${issue['line']}-${issue['message']}';
    if (_shownIssue == signature || !widget.active) return;
    _shownIssue = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final field = issue['field'];
      final controller = _text[field];
      if (controller == null) return;
      _focus[field]?.requestFocus();
      final start = ((issue['start'] as num?)?.toInt() ?? 0).clamp(
        0,
        controller.text.length,
      );
      final end = (start + ((issue['length'] as num?)?.toInt() ?? 0)).clamp(
        start,
        controller.text.length,
      );
      controller.selection = TextSelection(
        baseOffset: start,
        extentOffset: end,
      );
      final anchor = _anchors[field]?.currentContext;
      if (anchor != null) Scrollable.ensureVisible(anchor, alignment: .2);
    });
  }

  void _edit(String field, dynamic value) {
    _shownIssue = null;
    _writeFailure = null;
    _pending[field] = value;
    unawaited(_send());
    setState(() {});
  }

  Future<void> _send() {
    if (_savingChanges != null) return _savingChanges!;
    final owner = model, role = widget.window;
    unawaited(
      owner.platform('setDirty', {'dirty': true}).catchError((_) => null),
    );
    final sending = _drain(owner, role);
    _savingChanges = sending;
    return sending.whenComplete(() {
      _savingChanges = null;
      final dirty =
          _pending.isNotEmpty ||
          readMap(_settings(owner)['drafts'])[role] == true;
      unawaited(
        owner.platform('setDirty', {'dirty': dirty}).catchError((_) => null),
      );
      if (mounted) {
        _sync();
        setState(() {});
      }
    });
  }

  Future<void> _drain(LiveModel owner, String role) async {
    while (_pending.isNotEmpty) {
      final field = _pending.keys.first;
      final value = _pending.remove(field);
      try {
        await owner.command('rules.edit', {
          'window': role,
          'field': field,
          'value': value,
        });
      } catch (error) {
        _writeFailure = error.toString();
        _pending.putIfAbsent(field, () => value);
        return;
      }
    }
    _writeFailure = null;
  }

  Future<bool> _finishInput(bool save) async {
    await _savingChanges;
    if (!save) {
      _pending.clear();
      _writeFailure = null;
      return true;
    }
    if (_pending.isNotEmpty) await _send();
    return _writeFailure == null;
  }

  Future<void> _save() async {
    if (!await _finishInput(true)) throw LiveCommandError(_writeFailure!);
    await model.command('rules.save', {'window': widget.window});
  }

  Future<void> _file(String type) async {
    try {
      final path = await model.platform('pickFile', {'type': 'profile'});
      if (path is String) {
        await model.command('profile.import', {
          'type': type,
          'source': 'file',
          'value': path,
        });
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _address(
    String type, {
    String source = 'url',
    String initial = '',
    String? label,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddressDialog(
        model: model,
        type: type,
        source: source,
        initial: initial,
        label: label ?? '导入订阅地址',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final rules = _rules,
          issue = readMap(rules['issue']),
          profiles = _section(model, 'profiles');
      final disabled = rules.isEmpty || _settings(model)['busy'] == true;
      return Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              children: [
                _Section('代理规则', [
                  if (model.connected) _Hint('当前会话 · ${model.mode}'),
                  const Text('下次连接模式'),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'rule', label: Text('规则')),
                        ButtonSegment(value: 'global', label: Text('全局')),
                        ButtonSegment(value: 'direct', label: Text('直连')),
                      ],
                      selected: {(rules['mode'] ?? 'rule') as String},
                      onSelectionChanged: disabled
                          ? null
                          : (v) => _edit('mode', v.first),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开发者模式'),
                    subtitle: const Text('下次连接跳过校园 IPv6 检测和域名黑名单。'),
                    value: rules['devMode'] == true,
                    onChanged: disabled
                        ? null
                        : (v) async {
                            if (!v ||
                                await _confirm(
                                  context,
                                  '开启开发者模式？',
                                  '保存后，下次连接会跳过校园 IPv6 检测和域名黑名单。',
                                  '开启',
                                ))
                              _edit('devMode', v);
                          },
                  ),
                ]),
                _Section('域名与网段', [
                  for (final field in ['campus', 'blacklist'])
                    Padding(
                      key: _anchors[field],
                      padding: const EdgeInsets.only(top: 9, bottom: 7),
                      child: TextField(
                        controller: _text[field],
                        focusNode: _focus[field],
                        enabled: !disabled,
                        minLines: 2,
                        maxLines: 5,
                        onChanged: (value) => _edit(field, value),
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          labelText: field == 'campus' ? '校园白名单' : '黑名单',
                          helperText: field == 'campus'
                              ? '每行一个域名或 CIDR，例如 edu.cn。'
                              : '每行一个域名，例如 example.org。',
                          errorMaxLines: 3,
                          errorText: issue['field'] == field
                              ? issue['message']?.toString()
                              : null,
                        ),
                      ),
                    ),
                ]),
                for (final type in ['chain', 'cloud'])
                  _profile(type, profiles, disabled),
                _configurationCheck(model),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _writeFailure ??
                        (rules['dirty'] == true || _pending.isNotEmpty
                            ? '代理规则有未保存的更改'
                            : '代理规则已同步'),
                    maxLines: 2,
                  ),
                ),
                _Action('重新载入', () async {
                  await _savingChanges;
                  if (!context.mounted) return;
                  if (_rules['dirty'] != true ||
                      await _confirm(
                        context,
                        '重新载入代理规则？',
                        '此窗口的规则草稿将替换为已保存的内容。',
                        '重新载入',
                      )) {
                    await model.command('rules.reload', {
                      'window': widget.window,
                    });
                  }
                }),
                FilledButton(
                  onPressed: disabled ? null : () => _run(context, _save),
                  child: const Text('保存代理规则'),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _profile(String type, StateMap data, bool disabled) {
    final chain = type == 'chain', names = readStrings(data['${type}Names']);
    final locked =
        disabled ||
        (chain
            ? data['cloudEnabled'] == true
            : data['chainEnabled'] == true || data['cloudAllowed'] != true);
    final title = chain ? '链式代理' : '备用配置';
    return _Section(title, [
      if (!chain)
        _Hint(
          data['cloudAllowed'] == true
              ? '维护者公告已开放备用配置。'
              : '当前公告未开放备用配置，或缓存已过期。',
        ),
      if (!chain)
        Wrap(
          children: [
            _Action(
              '校园登录地址',
              () => _address(
                'cloud',
                source: 'portal',
                initial: data['portal']?.toString() ?? '',
                label: '校园登录页地址',
              ),
            ),
            _Action('刷新公告', () => model.command('notices.refresh')),
          ],
        ),
      Wrap(
        spacing: 4,
        children: [
          _Action(
            '导入文件',
            locked ? null : () => _file(type),
            icon: Icons.upload_file,
          ),
          _Action(
            '订阅地址',
            locked ? null : () => _address(type),
            icon: Icons.link,
          ),
          if (!chain)
            _Action(
              '从校园登录页获取',
              locked
                  ? null
                  : () => _address(
                      type,
                      source: 'portalFetch',
                      initial: data['portal']?.toString() ?? '',
                      label: '校园登录页地址',
                    ),
            ),
          if (['url', 'portal'].contains(data['${type}Source']))
            _Action(
              '刷新来源',
              locked
                  ? null
                  : () => model.command('profile.import', {
                      'type': type,
                      'source': 'refresh',
                    }),
            ),
        ],
      ),
      if (names.isNotEmpty) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('下次连接使用$title'),
          value: data['${type}Enabled'] == true,
          onChanged: disabled || (locked && data['${type}Enabled'] != true)
              ? null
              : (v) => _run(
                  context,
                  () => model.command('profile.enable', {
                    'type': type,
                    'enabled': v,
                  }),
                ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('${names.length} 个节点'),
          children: [
            for (final n in names)
              ListTile(dense: true, title: SelectableText(n)),
          ],
        ),
        Wrap(
          children: [
            _Action(
              '检查密钥',
              () => model.command('profile.checkKey', {'type': type}),
            ),
            _Action('清除…', () async {
              if (await _confirm(
                context,
                '清除$title？',
                '已导入的节点和存储的来源地址将移除。',
                '清除',
              ))
                await model.command('profile.clear', {'type': type});
            }),
          ],
        ),
      ],
    ]);
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog({
    required this.model,
    required this.type,
    required this.source,
    required this.initial,
    required this.label,
  });
  final LiveModel model;
  final String type, source, initial, label;
  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final input = TextEditingController(text: widget.initial);
  bool busy = false;
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    final value = input.text.trim(), source = widget.source;
    if (source == 'url') {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        setState(() => error = '请输入含主机名的 HTTP 或 HTTPS 地址。');
        return;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.model
          .command(source == 'portal' ? 'profile.portal' : 'profile.import', {
            'type': widget.type,
            'source': source == 'portalFetch' ? 'portal' : source,
            'value': value,
          });
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted)
        setState(() {
          busy = false;
          error = failure.toString();
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.label),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: input,
          autofocus: true,
          enabled: !busy,
          obscureText: widget.source == 'url',
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => error = null),
          onSubmitted: (_) => submit(),
          decoration: InputDecoration(
            labelText: widget.source == 'url' ? '来源地址' : '校园登录页地址',
            errorText: error,
            errorMaxLines: 3,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              busy || (input.text.trim().isEmpty && widget.source != 'portal')
              ? null
              : submit,
          child: Text(
            busy
                ? '正在处理…'
                : widget.source == 'portal'
                ? '保存地址'
                : '导入',
          ),
        ),
      ],
    ),
  );
}
