import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'pages.dart' show FreeV6SectionPage;

class FreeV6LicensesView extends StatefulWidget {
  const FreeV6LicensesView({super.key});
  @override
  State<FreeV6LicensesView> createState() => _FreeV6LicensesViewState();
}

class _FreeV6LicensesViewState extends State<FreeV6LicensesView> {
  late final entries = LicenseRegistry.licenses.toList();
  @override
  Widget build(BuildContext context) => FreeV6SectionPage(
    title: context.appLocalizations.freev6Licenses,
    sections: [
      generateSection(
        items: [
          for (final (name, asset) in [
            ('FreeV6 · MIT', 'assets/legal/FreeV6-LICENSE.txt'),
            ('FlClash · GPLv3', 'LICENSE'),
            ('Prism UI', 'plugins/prism_ui/LICENSE'),
            ('Prism UI · notices', 'plugins/prism_ui/NOTICE'),
          ])
            ListItem(
              title: Text(name),
              onTap: () async {
                final text = await rootBundle.loadString(asset);
                if (context.mounted) {
                  await dialogs.showAlert(
                    title: name,
                    message: TextSpan(text: text),
                  );
                }
              },
            ),
        ],
      ),
      FutureBuilder<List<LicenseEntry>>(
        future: entries,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Text(
              snapshot.hasError
                  ? '${snapshot.error}'
                  : context.appLocalizations.freev6Working,
            );
          }
          return generateSection(
            items: [
              for (final entry in snapshot.data!)
                ListItem(
                  title: Text(entry.packages.join(', ')),
                  onTap: () => dialogs.showAlert(
                    title: entry.packages.join(', '),
                    message: TextSpan(
                      text: entry.paragraphs.map((p) => p.text).join('\n\n'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}
