import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dns_queries.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart' show object;

import 'forms.dart';
import 'session.dart';

class FreeV6DnsView extends ConsumerStatefulWidget {
  const FreeV6DnsView({super.key});
  @override
  ConsumerState<FreeV6DnsView> createState() => _DnsState();
}

class _DnsState extends ConsumerState<FreeV6DnsView> {
  bool busy = false;
  String type = 'A';
  Future<bool> query(String domain) async {
    final model = ref.read(freev6SessionProvider).model;
    if (model is! LiveModel || !model.connected) return false;
    final clock = Stopwatch()..start();
    final time = DateTime.now();
    setState(() => busy = true);
    DnsQuery result;
    try {
      final data = await model.controller.call(
        ['dns', 'query'],
        query: {'name': domain, 'type': type},
      );
      result = DnsQuery(
        domain: domain,
        type: type,
        time: time,
        initiator: DnsQueryInitiator.app,
        delay: clock.elapsedMilliseconds,
        rcode: data['Status'] == 0 ? 'NOERROR' : '${data['Status']}',
        answers: (data['Answer'] as List? ?? [])
            .map((a) => '${object(a)['data']}')
            .toList(),
      );
    } catch (error) {
      result = DnsQuery(
        domain: domain,
        type: type,
        time: time,
        initiator: DnsQueryInitiator.app,
        delay: clock.elapsedMilliseconds,
        error: error.toString(),
      );
    }
    if (!mounted) return false;
    ref.read(dnsQueriesProvider.notifier).addQuery(result);
    ref.read(dnsQueryCountProvider.notifier).update((v) => v + 1);
    setState(() => busy = false);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final model = watchFreeV6(ref), l = context.appLocalizations;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(l.freev6DnsScope),
              for (final value in ['A', 'AAAA'])
                TextButton(
                  onPressed: busy ? null : () => setState(() => type = value),
                  child: Text(type == value ? '✓ $value' : value),
                ),
              TextButton(
                onPressed: busy || !model.connected
                    ? null
                    : () => dialogs.showCommonDialog<bool>(
                        child: FreeV6InputDialog(
                          title: l.freev6DnsQuery,
                          value: '',
                          save: query,
                          validate: (v) =>
                              v.isEmpty ||
                                  v.length > 253 ||
                                  RegExp(r'[\s/:]').hasMatch(v)
                              ? l.freev6DomainInvalid
                              : null,
                        ),
                      ),
                child: Text(l.freev6DnsQuery),
              ),
            ],
          ),
        ),
        const Expanded(child: DnsQueriesView()),
      ],
    );
  }
}
