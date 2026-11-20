import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/dashboard/dashboard.dart';
import 'package:fl_clash/views/logs.dart';
import 'package:fl_clash/views/proxies/proxies.dart';

import 'pages.dart';

class FreeV6Navigation implements NavigationPort {
  @override
  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) => [
    NavigationItem(
      glyph: AppGlyphs.dashboard,
      label: PageLabel.dashboard,
      builder: (_) => const DashboardView(),
    ),
    NavigationItem(
      glyph: AppGlyphs.proxies,
      label: PageLabel.proxies,
      builder: (_) => const ProxiesView(),
    ),
    NavigationItem(
      glyph: AppGlyphs.profiles,
      label: PageLabel.profiles,
      builder: (_) => const FreeV6ConfigurationView(),
    ),
    NavigationItem(
      glyph: AppGlyphs.logs,
      label: PageLabel.logs,
      builder: (_) => const LogsView(),
    ),
    NavigationItem(
      glyph: AppGlyphs.tools,
      label: PageLabel.tools,
      builder: (_) => const FreeV6SettingsView(),
    ),
  ];
}
