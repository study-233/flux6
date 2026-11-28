import 'dart:convert';

import 'package:fl_clash/common/app_localizations.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/proxies/group_tabs.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final groups = await loadPreviewGroups();
  runApp(NodePreview(groups: groups));
}

Future<List<Group>> loadPreviewGroups() async {
  final data = await rootBundle.loadString('assets/data/preview-groups.json');
  return [
    for (final group in (jsonDecode(data) as List).cast<Map<String, dynamic>>())
      Group(
        name: group['name'] as String,
        type: GroupType.Selector,
        hidden: false,
        all: [
          for (final name in (group['proxies'] as List).cast<String>())
            Proxy(name: name, type: ''),
        ],
      ),
  ];
}

class NodePreview extends StatelessWidget {
  const NodePreview({super.key, required this.groups});
  final List<Group> groups;

  @override
  Widget build(BuildContext context) {
    return PrismApp(
      title: 'Flux6 Preview',
      localizationsDelegates: const [
        AppLocalizations.delegate,
        AppUiLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      home: _GroupList(groups: groups),
    );
  }
}

class _GroupList extends StatefulWidget {
  const _GroupList({required this.groups});
  final List<Group> groups;

  @override
  State<_GroupList> createState() => _GroupListState();
}

class _GroupListState extends State<_GroupList>
    with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: widget.groups.length, vsync: this);

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            GroupTabs(controller: tabs, groups: widget.groups),
            Expanded(
              child: ListenableBuilder(
                listenable: tabs,
                builder: (context, _) {
                  final group = widget.groups[tabs.index];
                  return ListView.builder(
                    key: ValueKey(group.name),
                    itemCount: group.all.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Text(
                        group.all[index].name,
                        style: AppTextStyle.body.of(context),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
