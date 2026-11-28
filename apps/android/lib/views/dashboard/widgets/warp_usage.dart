import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/warp_setup.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../style.dart';

class WarpUsageButton extends ConsumerStatefulWidget {
  const WarpUsageButton({super.key}) : _details = false;
  const WarpUsageButton._details() : _details = true;

  final bool _details;

  @override
  ConsumerState<WarpUsageButton> createState() => _WarpUsageButtonState();
}

class _WarpUsageButtonState extends ConsumerState<WarpUsageButton>
    with WidgetsBindingObserver, ActivePollingMixin<WarpUsageButton> {
  ({Traffic month, Traffic total})? usage;
  bool? _onlyProxy;

  @override
  Duration get pollInterval => const Duration(seconds: 5);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    if (!ref.read(initProvider)) return;
    final onlyProxy = ref.read(appSettingProvider).onlyStatisticsProxy;
    final result = await ref
        .read(coreHandlerProvider)
        .getTrafficUsage(onlyProxy);
    if (isCurrent() && (result != usage || _onlyProxy != onlyProxy)) {
      setState(() {
        usage = result;
        _onlyProxy = onlyProxy;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final onlyProxy = ref.watch(
      appSettingProvider.select((v) => v.onlyStatisticsProxy),
    );
    final data = _onlyProxy == onlyProxy ? usage : null;
    final state = ref.watch(warpSetupProvider);
    final failure = switch (state) {
      WarpSetupStatus.storageFailed => labels.warpStoreFailed,
      WarpSetupStatus.registrationFailed => labels.warpRegisterFailed,
      WarpSetupStatus.profileFailed => labels.warpSetupFailed,
      _ => null,
    };
    String amount(num? bytes) => bytes == null ? '—' : dashboardTraffic(bytes);
    String directions(Traffic? sample) =>
        '${labels.upload} ${amount(sample?.up)}   ${labels.download} ${amount(sample?.down)}';
    if (widget._details) {
      return Scaffold(
        title: labels.trafficUsage,
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            context.contentTopPadding,
            16,
            context.bottomInset + 16,
          ),
          children: [
            if (state == WarpSetupStatus.preparing)
              Text(labels.freev6Preparing),
            if (state == WarpSetupStatus.ready) Text(labels.warpReady),
            if (failure != null)
              TextButton(
                onPressed: () => ref.read(warpSetupProvider.notifier).prepare(),
                child: Text('$failure · ${labels.retry}'),
              ),
            for (final row in [
              (labels.warpSessionUsage, ref.watch(totalTrafficProvider)),
              (labels.trafficThisMonth, data?.month),
              (labels.trafficAllTime, data?.total),
            ]) ...[
              Text(
                '${row.$1}  ${amount(row.$2?.speed)}',
                style: AppTextStyle.headline.of(context),
              ),
              Text(directions(row.$2)),
              const SizedBox(height: 12),
            ],
          ],
        ),
      );
    }
    final label =
        failure ??
        (state == WarpSetupStatus.preparing
            ? labels.freev6Preparing
            : '${labels.trafficThisMonth} ${amount(data?.month.speed)}');
    return Tooltip(
      message: labels.trafficUsage,
      child: TextButton(
        onPressed: () => showSheet<void>(
          context: context,
          builder: (_) => const WarpUsageButton._details(),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 128),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
