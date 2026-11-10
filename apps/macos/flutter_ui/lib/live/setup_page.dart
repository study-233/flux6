part of 'pages.dart';

class _SetupWizard extends StatelessWidget {
  const _SetupWizard({required this.model});
  final LiveModel model;
  static const steps = [
    ('安装网络服务', '仅在安装或修复服务时请求系统授权'),
    ('准备网络核心', '自动下载并校验，已有资源会复用'),
    ('准备规则数据', '自动检查并补齐连接所需的数据'),
    ('准备连接账户', '自动读取已有账户，缺少时自动注册'),
    ('检查连接配置', '确认资源与配置可以一起使用'),
  ];

  @override
  Widget build(BuildContext context) {
    final setup = readMap(model.state['setup']);
    final step = (setup['step'] as num? ?? 0).toInt().clamp(0, 5);
    final active = setup['active'] == true;
    final error = setup['error'] as String? ?? '';
    final done = step == 5 && error.isEmpty && !active;
    final colors = Theme.of(context).colorScheme;
    Future<void> finish(bool connect) async {
      await model.command('setup.finish');
      if (connect) await model.command('connect');
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 48, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                done ? '已经准备好了' : '完成首次配置',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                done ? '配置检查已通过，现在可以连接。' : '按顺序完成下面的步骤。中途暂停后，可从已完成的进度继续。',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Semantics(
                label: '已完成 $step 项，共 5 项',
                child: LinearProgressIndicator(value: step / steps.length),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < steps.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: i == step
                                ? colors.primaryContainer.withValues(alpha: .4)
                                : colors.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: i == step
                                  ? colors.primary.withValues(alpha: .5)
                                  : colors.outlineVariant,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: i < step
                                      ? Icon(
                                          Icons.check_circle_rounded,
                                          color: colors.primary,
                                        )
                                      : i == step && active
                                      ? const CircularProgressIndicator(
                                          strokeWidth: 2,
                                        )
                                      : Center(
                                          child: Text(
                                            '${i + 1}',
                                            style: TextStyle(
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        steps[i].$1,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        i == step && active
                                            ? setup['status']?.toString() ?? ''
                                            : steps[i].$2,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (i < step)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 12),
                                    child: Text('已完成'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (active)
                Semantics(
                  liveRegion: true,
                  child: Text(setup['status']?.toString() ?? '正在配置…'),
                ),
              if (error.isNotEmpty)
                Semantics(
                  liveRegion: true,
                  child: Text(error, style: TextStyle(color: colors.error)),
                ),
              if (done)
                Text(
                  setup['status']?.toString() ?? '',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              if (!done && step == 0 && !active)
                Text(
                  '点击开始后，macOS 可能要求授权安装。之后会自动完成资源与账户准备。',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (active)
                    TextButton(
                      onPressed: () =>
                          _run(context, () => model.command('setup.cancel')),
                      child: const Text('暂停配置'),
                    ),
                  if (done)
                    TextButton(
                      onPressed: () => _run(context, () => finish(false)),
                      child: const Text('进入首页'),
                    ),
                  FilledButton.icon(
                    onPressed: active || model.busy
                        ? null
                        : () => _run(
                            context,
                            () => done
                                ? finish(true)
                                : model.command('setup.start'),
                          ),
                    icon: Icon(
                      done
                          ? Icons.power_settings_new
                          : Icons.arrow_forward_rounded,
                    ),
                    label: Text(
                      done
                          ? '完成并连接'
                          : active
                          ? '正在配置…'
                          : error.isNotEmpty
                          ? '继续配置'
                          : '开始配置',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
