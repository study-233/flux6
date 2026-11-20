import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/proxies/group_tabs.dart';
import 'package:prism_ui/prism_ui.dart' show TabController;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// The native host owns session state and menu commands. Only page selection
// and window layout pass through the FlClash home shell.
class MacNavigation extends StatelessWidget {
  const MacNavigation(
    this.pages,
    this.index,
    this.onSelect,
    this.onQuit, {
    super.key,
  });

  final List<Widget> pages;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onQuit;

  static const labels = [
    PageLabel.dashboard,
    PageLabel.proxies,
    PageLabel.profiles,
    PageLabel.logs,
  ];
  static const glyphs = [
    AppGlyphs.dashboard,
    AppGlyphs.proxies,
    AppGlyphs.profiles,
    AppGlyphs.logs,
  ];

  @override
  Widget build(BuildContext context) => Localizations.override(
    context: context,
    delegates: const [AppLocalizations.delegate],
    child: ProviderScope(
      overrides: [
        navigationItemsStateProvider.overrideWith(
          (_) => NavigationItemsState(
            value: [
              for (var i = 0; i < pages.length; i++)
                NavigationItem(
                  label: labels[i],
                  glyph: glyphs[i],
                  builder: (_) => pages[i],
                ),
            ],
          ),
        ),
        systemActionProvider.overrideWith(() => _MacSystemAction(onQuit)),
      ],
      child: _Home(index, onSelect),
    ),
  );
}

class _MacSystemAction extends SystemAction {
  _MacSystemAction(this.quit);
  final VoidCallback quit;
  @override
  Future<void> handleClose([bool exit = true]) async => quit();
}

class _Home extends ConsumerStatefulWidget {
  const _Home(this.index, this.onSelect);

  final int index;
  final ValueChanged<int> onSelect;
  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> {
  bool syncQueued = false;

  void syncLayout() {
    if (syncQueued) return;
    syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      syncQueued = false;
      if (!mounted) return;
      ref.read(viewSizeProvider.notifier).value = MediaQuery.sizeOf(context);
      final page = MacNavigation.labels[widget.index];
      if (ref.read(currentPageLabelProvider) != page) {
        ref.read(currentPageLabelProvider.notifier).toPage(page);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    MediaQuery.sizeOf(context);
    syncLayout();
    ref.listen(currentPageLabelProvider, (_, next) {
      final index = MacNavigation.labels.indexOf(next);
      if (index >= 0 && index != widget.index) widget.onSelect(index);
    });
    return const HomePage();
  }
}

class MacNodeGroups extends StatefulWidget {
  const MacNodeGroups(this.labels, this.selected, this.onSelect, {super.key});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  State<MacNodeGroups> createState() => _MacNodeGroupsState();
}

class _MacNodeGroupsState extends State<MacNodeGroups>
    with TickerProviderStateMixin {
  late TabController tabs = _makeController();
  TabController _makeController() => TabController(
    length: widget.labels.length,
    initialIndex: widget.selected.clamp(0, widget.labels.length - 1),
    vsync: this,
  )..addListener(_selected);
  void _selected() {
    if (tabs.index != widget.selected && tabs.indexIsChanging) {
      widget.onSelect(tabs.index);
    }
  }

  @override
  void didUpdateWidget(MacNodeGroups oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.labels.length != widget.labels.length) {
      tabs.dispose();
      tabs = _makeController();
    } else if (widget.selected >= 0 && tabs.index != widget.selected) {
      tabs.index = widget.selected;
    }
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GroupTabs(
    controller: tabs,
    groups: [
      for (final label in widget.labels)
        Group(
          name: label,
          type: GroupType.Selector,
          hidden: false,
          all: const [],
        ),
    ],
  );
}
