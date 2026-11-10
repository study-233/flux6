import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerComponentLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in {
      'FlClash': 'vendor/flclash/LICENSE',
      'Prism UI': 'vendor/prism_ui/LICENSE',
      'Prism UI third-party notices': 'vendor/prism_ui/NOTICE',
      'Flutter Windows runner': 'vendor/Flutter-LICENSE',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString(entry.value));
    }
  });
}
