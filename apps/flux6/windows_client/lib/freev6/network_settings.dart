import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart' show object;

import 'forms.dart';
import 'pages.dart';
import 'session.dart';

class FreeV6NetworkView extends ConsumerWidget {
  const FreeV6NetworkView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = watchFreeV6(ref), l = context.appLocalizations;
    final session = ref.read(freev6SessionProvider);
    if (model is! LiveModel) return Center(child: Text(l.freev6Offline));
    final options = model.networkOptions;
    Widget choice(
      String key,
      String title,
      List<String> values,
      String fallback,
    ) => ListItem<String>.options(
      title: Text(title),
      options: values,
      value: options[key]?.toString() ?? fallback,
      textBuilder: (v) => v,
      onChanged: (v) {
        if (!model.busy) session.act('network.save', {key: v});
      },
    );
    return FreeV6SectionPage(
      title: l.freev6NetworkSettings,
      sections: [
        generateSection(
          title: 'DNS',
          footer: l.freev6DnsSettingsHint,
          items: [
            choice('dnsMode', l.freev6DnsMode, [
              'fake-ip',
              'redir-host',
            ], 'fake-ip'),
            ListItem(
              title: Text(l.freev6Nameservers),
              subtitle: Text(
                (options['nameservers'] as List? ?? []).join('\n'),
              ),
              onTap: model.busy
                  ? null
                  : () => dialogs.showCommonDialog<bool>(
                      child: FreeV6InputDialog(
                        title: l.freev6Nameservers,
                        value: (options['nameservers'] as List? ?? []).join(
                          '\n',
                        ),
                        multiline: true,
                        save: (v) => session.act('network.save', {
                          'nameservers': v
                              .split(RegExp(r'\s+'))
                              .where((s) => s.isNotEmpty)
                              .toList(),
                        }),
                      ),
                    ),
            ),
          ],
        ),
        generateSection(
          title: 'TUN',
          footer: l.freev6ReconnectHint,
          items: [
            choice('tunStack', l.freev6TunStack, [
              'mixed',
              'system',
              'gvisor',
            ], 'mixed'),
            ListItem(
              title: const Text('MTU'),
              subtitle: Text('${options['tunMtu'] ?? 0}'),
              onTap: model.busy
                  ? null
                  : () => dialogs.showCommonDialog<bool>(
                      child: FreeV6InputDialog(
                        title: 'MTU',
                        value: '${options['tunMtu'] ?? 0}',
                        validate: (v) {
                          final mtu = int.tryParse(v);
                          return mtu != null &&
                                  (mtu == 0 || mtu >= 1280 && mtu <= 9000)
                              ? null
                              : l.freev6MtuHint;
                        },
                        save: (v) => session.act('network.save', {
                          'tunMtu': int.parse(v),
                        }),
                      ),
                    ),
            ),
          ],
        ),
        generateSection(
          title: l.logs,
          footer: l.freev6ReconnectHint,
          items: [
            choice('logLevel', l.freev6LogLevel, [
              'info',
              'warning',
              'error',
              'debug',
              'silent',
            ], 'info'),
          ],
        ),
        generateSection(
          items: [
            ListItem.open(
              title: Text(l.freev6EffectiveRules),
              widget: const FreeV6RulesView(),
            ),
          ],
        ),
      ],
    );
  }
}

class FreeV6RulesView extends ConsumerStatefulWidget {
  const FreeV6RulesView({super.key});
  @override
  ConsumerState<FreeV6RulesView> createState() => _RulesState();
}

class _RulesState extends ConsumerState<FreeV6RulesView> {
  List<Map<String, dynamic>> rules = [];
  String query = '';
  Object? error;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final model = ref.read(freev6SessionProvider).model;
    if (model is! LiveModel || !model.connected) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await model.controller.call(['rules']);
      if (mounted) {
        setState(
          () => rules = (result['rules'] as List? ?? []).map(object).toList(),
        );
      }
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final filtered = rules
        .where(
          (r) => '${r['type']} ${r['payload']} ${r['proxy']}'
              .toLowerCase()
              .contains(query.toLowerCase()),
        )
        .toList();
    return Scaffold(
      title: l.freev6EffectiveRules,
      searchState: AppBarSearchState(
        onSearch: (v) => setState(() => query = v),
      ),
      body: error != null
          ? Center(
              child: TextButton(
                onPressed: load,
                child: Text('$error · ${l.freev6Refresh}'),
              ),
            )
          : loading
          ? Center(child: Text(l.freev6Working))
          : rules.isEmpty
          ? Center(child: Text(l.freev6RulesConnect))
          : ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (_, i) {
                final rule = filtered[i];
                return ListItem(
                  title: Text('${rule['payload'] ?? rule['type']}'),
                  subtitle: Text('${rule['type']}'),
                  trailing: Text('${rule['proxy']}'),
                );
              },
            ),
    );
  }
}
